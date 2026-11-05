import XCTest

/// Offline discovery uses the same picker from template drafts and active workouts.
final class ExerciseDiscoveryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testEquipmentMuscleAndTypeCombineWithSearchAndClearNoMatches() {
        let app = launchApp()
        defer { app.terminate() }
        openTemplatePicker(in: app)

        setFilters(equipment: "Barbell", muscle: "Chest", type: "Strength", in: app)
        XCTAssertTrue(app.buttons["exercise-Bench Press"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["exercise-Squat"].exists)
        XCTAssertFalse(app.buttons["exercise-Dumbbell Curl"].exists)

        search("bEnCh", in: app)
        XCTAssertTrue(app.buttons["exercise-Bench Press"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["exercise-Squat"].exists)
        search("", in: app)
        XCTAssertTrue(app.buttons["exercise-Bench Press"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["exercise-Squat"].exists, "Clearing search must retain the selected metadata filters")
        assertSelectedFilters(equipment: "Barbell", muscle: "Chest", type: "Strength", in: app)

        search("Dumbbell Curl", in: app)
        XCTAssertTrue(app.staticTexts["No matching exercises"].waitForExistence(timeout: 5))
        keepScreenshot(of: app, named: "Discovery no matches with combined filters")
        app.buttons["clearExerciseFiltersButton"].tap()
        XCTAssertTrue(app.buttons["exercise-Dumbbell Curl"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "Dumbbell Curl", "Clearing metadata filters preserves the search")
        setFilters(equipment: "Barbell", muscle: "Chest", type: "Strength", in: app)
        XCTAssertTrue(app.staticTexts["No matching exercises"].waitForExistence(timeout: 5))
        app.buttons["clearExerciseSearchAndFiltersButton"].tap()
        XCTAssertTrue(app.buttons["exercise-Bench Press"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["exercise-Squat"].exists)
        XCTAssertFalse(app.staticTexts["No matching exercises"].exists)
        assertSelectedFilters(equipment: "All", muscle: "All", type: "All", in: app)
    }

    @MainActor
    func testReadingDetailsAndCancellingDoesNotAddUntilExplicitSelection() {
        let app = launchApp()
        defer { app.terminate() }
        openTemplatePicker(in: app)
        openDetail("Bench Press", in: app)
        XCTAssertEqual(app.staticTexts["exerciseDetailName"].label, "Bench Press")
        let instructions = app.descendants(matching: .any).matching(identifier: "exerciseInstructionStep-1").firstMatch
        scrollTo(instructions, in: app)
        XCTAssertTrue(instructions.label.contains("Lie back on a flat bench"), "Bundled default steps are readable immediately")
        XCTAssertFalse(app.staticTexts["exerciseInstructionsUnavailable"].exists)
        keepScreenshot(of: app, named: "Exercise detail with default instructions")

        backToPicker(in: app)
        app.buttons["exercisePickerCancelButton"].tap()
        XCTAssertTrue(app.navigationBars["New Template"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Remove Bench Press"].exists)
        XCTAssertFalse(app.textFields["setReps-1"].exists)

        openPicker(in: app)
        openDetail("Bench Press", in: app)
        let add = app.buttons["exerciseDetailAddButton"]
        scrollTo(add, in: app)
        add.tap()
        XCTAssertTrue(app.buttons["Remove Bench Press"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields.matching(identifier: "setReps-1").count, 1)
        app.navigationBars["New Template"].buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["createTemplateButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testFavoritesPersistAndRemovalSurvivesRelaunchWithoutSavingADraft() {
        let app = launchApp()
        defer { app.terminate() }
        openTemplatePicker(in: app)
        XCTAssertFalse(app.staticTexts["exerciseSection-favorites"].exists)
        openDetail("Bench Press", in: app)
        let favorite = app.buttons["exerciseFavoriteButton"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        XCTAssertEqual(favorite.label, "Add to Favorites")
        favorite.tap()
        XCTAssertEqual(favorite.label, "Remove from Favorites")
        backToPicker(in: app)
        XCTAssertTrue(app.staticTexts["exerciseSection-favorites"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "exercise-Bench Press").count, 1, "Featured exercises must not be duplicated in All Exercises")
        keepScreenshot(of: app, named: "Favorite exercise in picker")
        app.buttons["exercisePickerCancelButton"].tap()
        app.navigationBars["New Template"].buttons["Cancel"].tap()

        relaunch(app)
        openTemplatePicker(in: app)
        XCTAssertTrue(app.staticTexts["exerciseSection-favorites"].waitForExistence(timeout: 5))
        openDetail("Bench Press", in: app)
        XCTAssertEqual(favorite.label, "Remove from Favorites")
        favorite.tap()
        XCTAssertEqual(favorite.label, "Add to Favorites")

        relaunch(app)
        openTemplatePicker(in: app)
        XCTAssertFalse(app.staticTexts["exerciseSection-favorites"].exists)
        openDetail("Bench Press", in: app)
        XCTAssertEqual(favorite.label, "Add to Favorites")
    }

    @MainActor
    func testFavoritesPreserveSavedOrderAcrossSearchFiltersAndRelaunch() {
        let app = launchApp()
        defer { app.terminate() }
        openTemplatePicker(in: app)

        // Save in the opposite order to these exercises' bundled catalog order.
        for name in ["Overhead Press", "Bench Press"] {
            search(name, in: app)
            openDetail(name, in: app)
            let favorite = app.buttons["exerciseFavoriteButton"]
            XCTAssertTrue(favorite.waitForExistence(timeout: 5))
            XCTAssertEqual(favorite.label, "Add to Favorites")
            favorite.tap()
            XCTAssertEqual(favorite.label, "Remove from Favorites")
            backToPicker(in: app)
        }

        search("", in: app)
        assertOverheadBeforeBenchInFavorites(in: app)
        keepScreenshot(of: app, named: "Favorites preserve saved order in unfiltered picker")
        search("press", in: app)
        assertOverheadBeforeBenchInFavorites(in: app)
        setFilters(equipment: "Barbell", muscle: "Triceps", type: "Strength", in: app)
        assertOverheadBeforeBenchInFavorites(in: app)
        app.buttons["exercisePickerCancelButton"].tap()
        app.navigationBars["New Template"].buttons["Cancel"].tap()

        relaunch(app)
        openTemplatePicker(in: app)
        assertOverheadBeforeBenchInFavorites(in: app)
        search("press", in: app)
        assertOverheadBeforeBenchInFavorites(in: app)
        keepScreenshot(of: app, named: "Favorites preserve saved order during search after relaunch")
        setFilters(equipment: "Barbell", muscle: "Triceps", type: "Strength", in: app)
        assertOverheadBeforeBenchInFavorites(in: app)
        keepScreenshot(of: app, named: "Favorites preserve saved order with search and metadata filters after relaunch")
    }

    @MainActor
    func testRecentsComeFromCompletedHistoryAndExcludeUncompletedExercises() {
        let app = launchApp()
        defer { app.terminate() }
        app.buttons["startEmptyWorkoutButton"].tap()
        addExercise("Bench Press", in: app)
        openPicker(in: app)
        XCTAssertFalse(app.staticTexts["exerciseSection-recentlyTrained"].exists, "An active workout alone is not completed training history")
        app.buttons["exercisePickerCancelButton"].tap()

        let complete = app.buttons["completeSet-1"]
        scrollTo(complete, in: app, upward: false)
        complete.tap()
        addExercise("Squat", in: app)
        app.buttons["finishWorkoutButton"].tap()
        app.buttons["confirmFinishWorkoutButton"].firstMatch.tap()
        XCTAssertTrue(app.buttons["closeWorkoutSummaryButton"].waitForExistence(timeout: 5))
        app.buttons["closeWorkoutSummaryButton"].tap()
        XCTAssertTrue(app.buttons["createTemplateButton"].waitForExistence(timeout: 5))

        relaunch(app)
        openTemplatePicker(in: app)
        XCTAssertTrue(app.staticTexts["exerciseSection-recentlyTrained"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "exercise-Bench Press").count, 1)
        keepScreenshot(of: app, named: "Recently trained from completed workout")
        search("Bench Press", in: app)
        XCTAssertTrue(app.staticTexts["exerciseSection-recentlyTrained"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "exercise-Bench Press").count, 1, "The recent exercise also matches search without being duplicated in All Exercises")
        search("Squat", in: app)
        XCTAssertTrue(app.buttons["exercise-Squat"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["exerciseSection-recentlyTrained"].exists, "An uncompleted exercise must not become recent")
        XCTAssertTrue(app.staticTexts["exerciseSection-allExercises"].exists)
    }

    @MainActor
    func testCustomExerciseRemainsReusableAfterDiscardWithClearUnknownMetadata() {
        let app = launchApp()
        defer { app.terminate() }
        let name = "Discovery Sled Drag"
        app.buttons["startEmptyWorkoutButton"].tap()
        openPicker(in: app)
        let searchField = app.searchFields.firstMatch
        searchField.tap()
        searchField.typeText(name)
        let custom = app.buttons["addCustomExerciseButton"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        XCTAssertTrue(custom.isHittable, "Custom creation stays visible above the empty state while the keyboard is open")
        keepScreenshot(of: app, named: "Create custom exercise with keyboard open")
        custom.tap()
        XCTAssertTrue(app.buttons["addSet-\(name)"].waitForExistence(timeout: 5))
        let discard = app.buttons["discardWorkoutButton"]
        scrollTo(discard, in: app)
        discard.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Discard Workout", "discardWorkoutButton")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["finishWorkoutButton"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["startEmptyWorkoutButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["resumeWorkoutButton"].exists, "Confirming discard must remove the active workout before relaunch")
        XCTAssertTrue(app.buttons["createTemplateButton"].waitForExistence(timeout: 5))

        relaunch(app)
        openTemplatePicker(in: app)
        search(name, in: app)
        XCTAssertTrue(app.buttons["exercise-\(name)"].waitForExistence(timeout: 5), "A committed custom exercise remains reusable after its workout is discarded")
        setFilters(equipment: "Unknown", muscle: "Unknown", type: "Unknown", in: app)
        XCTAssertTrue(app.buttons["exercise-\(name)"].waitForExistence(timeout: 5), "Unknown metadata filters must include a custom exercise without source details")
        search("  discovery   SLED drag ", in: app)
        XCTAssertTrue(app.buttons["exercise-\(name)"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "exercise-\(name)").count, 1)
        XCTAssertFalse(app.buttons["addCustomExerciseButton"].exists)
        openDetail(name, in: app)
        let metadata = app.staticTexts["exerciseMetadataUnavailable"]
        scrollTo(metadata, in: app)
        XCTAssertFalse(metadata.label.isEmpty)
        keepScreenshot(of: app, named: "Reusable custom exercise with unknown metadata")
        for title in ["Equipment", "Primary muscles", "Secondary muscles", "Type"] {
            let field = app.descendants(matching: .any)["exerciseMetadata-\(title)"].firstMatch
            scrollTo(field, in: app, upward: title != "Equipment")
            XCTAssertTrue(field.label.contains("Unknown"), "Custom \(title) must not be inferred from its name or category")
        }
        backToPicker(in: app)
        app.buttons["exercise-\(name)"].tap()
        XCTAssertTrue(app.buttons["Remove \(name)"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["setReps-1"].exists)
    }

    @MainActor
    func testMissingSourceInstructionsAreClearlyUnavailable() {
        let app = launchApp()
        defer { app.terminate() }
        openTemplatePicker(in: app)
        search("Iron Cross", in: app)
        openDetail("Iron Cross", in: app)
        let unavailable = app.staticTexts["exerciseInstructionsUnavailable"]
        scrollTo(unavailable, in: app)
        XCTAssertEqual(unavailable.label, "No default steps available")
        XCTAssertTrue(app.buttons["addExerciseInstructionsButton"].exists)
        keepScreenshot(of: app, named: "Source exercise with missing instructions")
    }

    /// Run once per simulator appearance (light and dark); attachments preserve the running UI.
    @MainActor
    func testDiscoveryScreensAtAccessibilityTextSize() {
        let app = launchApp(largeText: true)
        defer { app.terminate() }
        openTemplatePicker(in: app)
        keepScreenshot(of: app, named: "Discovery picker accessibility XXXL")
        openFilters(in: app)
        keepScreenshot(of: app, named: "Discovery filters accessibility XXXL")
        app.buttons["exerciseFiltersDoneButton"].tap()
        openDetail("Bench Press", in: app)
        let add = app.buttons["exerciseDetailAddButton"]
        scrollTo(add, in: app)
        keepScreenshot(of: app, named: "Exercise detail accessibility XXXL")
        let instructions = app.descendants(matching: .any).matching(identifier: "exerciseInstructionStep-1").firstMatch
        scrollTo(instructions, in: app)
        keepScreenshot(of: app, named: "Exercise default instructions accessibility XXXL")
    }

    @MainActor
    private func launchApp(largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        // Apply fixture arguments to a new process, including on the first test launch.
        app.terminate()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["createTemplateButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["startEmptyWorkoutButton"].waitForExistence(timeout: 5), "The reset fixture must start without an active workout")
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
    private func openTemplatePicker(in app: XCUIApplication) {
        app.buttons["createTemplateButton"].tap()
        openPicker(in: app)
    }

    @MainActor
    private func openPicker(in app: XCUIApplication) {
        let add = app.buttons["addExerciseButton"]
        scrollTo(add, in: app)
        add.tap()
        XCTAssertTrue(app.navigationBars["Add Exercise"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func addExercise(_ name: String, in app: XCUIApplication) {
        openPicker(in: app)
        let exercise = app.buttons["exercise-\(name)"]
        scrollTo(exercise, in: app)
        exercise.tap()
        XCTAssertTrue(app.navigationBars["Add Exercise"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["finishWorkoutButton"].waitForExistence(timeout: 5))
        let editor = app.collectionViews["activeWorkoutEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let addSet = editor.buttons["addSet-\(name)"]
        // The active workout List creates lower exercise rows as they scroll
        // into view. Reveal the added exercise on its owning list first.
        for _ in 0..<15 {
            if addSet.isHittable { break }
            editor.swipeUp()
        }
        XCTAssertTrue(addSet.isHittable, "The added exercise must be visible in the active workout")
    }

    @MainActor
    private func openDetail(_ name: String, in app: XCUIApplication) {
        let info = app.buttons["exerciseInfo-\(name)"]
        scrollTo(info, in: app)
        info.tap()
        XCTAssertTrue(app.staticTexts["exerciseDetailName"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func backToPicker(in app: XCUIApplication) {
        // Scope to the visible detail bar; the presenting template has its own Cancel.
        app.navigationBars["Exercise Details"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Add Exercise"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func openFilters(in app: XCUIApplication) {
        app.buttons["exerciseFilterButton"].tap()
        XCTAssertTrue(app.buttons["exerciseFiltersDoneButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func setFilters(equipment: String, muscle: String, type: String, in app: XCUIApplication) {
        openFilters(in: app)
        for (identifier, option) in [("exerciseEquipmentFilter", equipment), ("exerciseMuscleFilter", muscle), ("exerciseTypeFilter", type)] {
            let picker = app.buttons[identifier]
            scrollTo(picker, in: app)
            picker.tap()
            let selection = app.buttons[option].firstMatch
            scrollTo(selection, in: app)
            selection.tap()
            XCTAssertTrue(app.buttons["exerciseFiltersDoneButton"].waitForExistence(timeout: 5))
        }
        app.buttons["exerciseFiltersDoneButton"].tap()
        XCTAssertTrue(app.navigationBars["Add Exercise"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func assertSelectedFilters(equipment: String, muscle: String, type: String, in app: XCUIApplication) {
        openFilters(in: app)
        for (identifier, option) in [("exerciseEquipmentFilter", equipment), ("exerciseMuscleFilter", muscle), ("exerciseTypeFilter", type)] {
            let picker = app.buttons[identifier]
            scrollTo(picker, in: app)
            XCTAssertTrue(picker.label.contains(option) || (picker.value as? String) == option, "\(identifier) should retain \(option)")
        }
        app.buttons["exerciseFiltersDoneButton"].tap()
    }

    @MainActor
    private func assertOverheadBeforeBenchInFavorites(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts["exerciseSection-favorites"].waitForExistence(timeout: 5), file: file, line: line)
        let overhead = app.buttons["exercise-Overhead Press"]
        let bench = app.buttons["exercise-Bench Press"]
        XCTAssertTrue(overhead.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(bench.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(app.buttons.matching(identifier: "exercise-Overhead Press").count, 1, file: file, line: line)
        XCTAssertEqual(app.buttons.matching(identifier: "exercise-Bench Press").count, 1, file: file, line: line)
        XCTAssertTrue(overhead.isHittable, file: file, line: line)
        XCTAssertTrue(bench.isHittable, file: file, line: line)
        XCTAssertLessThan(overhead.frame.minY, bench.frame.minY,
                          "Favorites must keep the saved Overhead Press then Bench Press order", file: file, line: line)
    }

    @MainActor
    private func search(_ text: String, in app: XCUIApplication) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let current = field.value as? String ?? ""
        if !current.isEmpty && current != field.placeholderValue {
            // Tapping an existing query can place the cursor in its middle. The
            // native clear control replaces the whole query regardless of cursor.
            let clear = field.buttons["Clear text"]
            XCTAssertTrue(clear.waitForExistence(timeout: 5))
            clear.tap()
        }
        if !text.isEmpty {
            field.typeText(text)
            XCTAssertEqual(field.value as? String, text, "Exercise search must receive the intended query")
            field.typeText("\n")
        }
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = true) {
        for _ in 0..<15 {
            if element.isHittable { return }
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
