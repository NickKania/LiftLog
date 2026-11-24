import XCTest

final class SupersetUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSharedMenuOffersActionsForRepeatedExercisesInThreeMemberSuperset() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--exercise-order-ui-fixture"]
        app.launch()
        defer { app.terminate() }

        let resume = app.buttons["resumeWorkoutButton"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        openSupersetEditor(for: "Bench Press", editing: true, active: true, in: app)
        candidate("Bench Press", index: 3, in: app).tap()
        app.buttons["saveSupersetButton"].tap()

        let menu = supersetMenu("Superset A", in: app)
        reveal(menu, in: app)
        let names = supersetNames(in: app)
        XCTAssertEqual(names.label, "Bench Press · Barbell Row · Bench Press")
        XCTAssertEqual(supersetMenus(in: app).count, 1)
        XCTAssertLessThan(names.frame.maxX, menu.frame.minX)
        menu.tap()
        let thirdExercise = app.buttons["Bench Press (3)"]
        XCTAssertTrue(thirdExercise.waitForExistence(timeout: 5))
        thirdExercise.tap()
        let removeMembership = app.buttons["Remove from Superset"]
        XCTAssertTrue(removeMembership.waitForExistence(timeout: 5))
        removeMembership.tap()
        XCTAssertEqual(names.label, "Bench Press · Barbell Row")
        let addSetButtons = app.buttons.matching(identifier: "addSet-Bench Press")
        XCTAssertTrue(addSetButtons.firstMatch.exists, "Removing membership keeps the exercise in the workout")
    }

    @MainActor
    func testWorkoutSupersetDisplaysAndEditsDifferentRestTimesBetweenSets() {
        let app = launchFreshApp()
        defer { app.terminate() }
        addUIInterruptionMonitor(withDescription: "Rest notification permission") { alert in
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            return false
        }
        beginTemplate(named: "Superset Rest Times", in: app)
        addExercise("Bench Press", in: app)
        addExercise("Squat", in: app)
        let firstTemplateRest = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'templateExerciseRest-'")).element(boundBy: 0)
        reveal(firstTemplateRest, in: app)
        firstTemplateRest.tap()
        setUseWorkoutDefault(false, in: app)
        app.buttons["restPreset-30"].tap()
        app.buttons["saveRestSettingsButton"].tap()
        openSupersetEditor(for: "Bench Press", in: app)
        candidate("Squat", index: 2, in: app).tap()
        app.buttons["saveSupersetButton"].tap()
        app.buttons["saveTemplateButton"].tap()

        startNewestTemplate(in: app)
        for name in ["Bench Press", "Squat"] {
            let add = app.buttons["addSet-\(name)"]
            reveal(add, in: app)
            add.tap()
        }

        func orderedSetRows() -> [(setID: String, name: String)] {
            var rows: [(setID: String, name: String)] = []
            for _ in 0..<6 {
                let elements = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "supersetSetExercise-")).allElementsBoundByIndex
                for element in elements {
                    let setID = String(element.identifier.dropFirst("supersetSetExercise-".count))
                    if !rows.contains(where: { $0.setID == setID }) {
                        rows.append((setID, element.label))
                    }
                }
                if rows.count == 4 { break }
                app.swipeUp()
            }
            return rows
        }

        let rows = orderedSetRows()
        XCTAssertEqual(rows.map(\.name), ["Bench Press", "Squat", "Bench Press", "Squat"])

        let groupMenu = supersetMenu("Superset A", in: app)
        reveal(groupMenu, in: app)
        XCTAssertEqual(supersetNames(in: app).label, "Bench Press · Squat")
        XCTAssertEqual(supersetMenus(in: app).count, 1)
        XCTAssertFalse(exerciseMenu("Bench Press", active: true, in: app).exists)
        XCTAssertFalse(exerciseMenu("Squat", active: true, in: app).exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Rest for ")).firstMatch.exists)

        let rest0 = app.staticTexts["workoutSetRest-\(rows[0].setID)"]
        let rest1 = app.staticTexts["workoutSetRest-\(rows[1].setID)"]
        let rest2 = app.staticTexts["workoutSetRest-\(rows[2].setID)"]
        let rest3 = app.staticTexts["workoutSetRest-\(rows[3].setID)"]

        reveal(rest0, in: app)
        XCTAssertTrue(rest0.label.contains("Bench Press") && rest0.label.contains("0:30"))
        assertRestBetween(rest0, afterSetID: rows[0].setID, beforeSetID: rows[1].setID, in: app)

        reveal(rest1, in: app)
        XCTAssertTrue(rest1.label.contains("Squat") && rest1.label.contains("Workout default (2:00)"))
        assertRestBetween(rest1, afterSetID: rows[1].setID, beforeSetID: rows[2].setID, in: app)

        reveal(rest2, in: app)
        XCTAssertTrue(rest2.label.contains("Bench Press") && rest2.label.contains("0:30"))
        assertRestBetween(rest2, afterSetID: rows[2].setID, beforeSetID: rows[3].setID, in: app)
        XCTAssertFalse(rest3.exists, "The final set in a superset should not display a between-set rest divider")

        reveal(groupMenu, in: app)
        groupMenu.tap()
        let benchActions = app.buttons["Bench Press"]
        XCTAssertTrue(benchActions.waitForExistence(timeout: 5))
        benchActions.tap()
        let restAction = app.buttons["exerciseRestSettingsButton"]
        XCTAssertTrue(restAction.waitForExistence(timeout: 5))
        restAction.tap()
        XCTAssertTrue(app.buttons["restPreset-0"].waitForExistence(timeout: 5))
        app.buttons["restPreset-0"].tap()
        app.buttons["saveRestSettingsButton"].tap()
        reveal(rest0, in: app)
        XCTAssertTrue(rest0.label.contains("Off"))
        reveal(rest2, in: app)
        XCTAssertTrue(rest2.label.contains("Off"))
        reveal(rest1, in: app)
        XCTAssertTrue(rest1.label.contains("Workout default (2:00)"))

        let workoutRest = app.buttons["workoutRestSettingsButton"]
        reveal(workoutRest, in: app)
        workoutRest.tap()
        XCTAssertTrue(app.buttons["restPreset-60"].waitForExistence(timeout: 5))
        app.buttons["restPreset-60"].tap()
        app.buttons["saveRestSettingsButton"].tap()
        reveal(rest1, in: app)
        XCTAssertTrue(rest1.label.contains("Workout default (1:00)"))
        reveal(rest0, in: app)
        XCTAssertTrue(rest0.label.contains("Off"))

        let firstRow = app.descendants(matching: .any).matching(identifier: "workoutSetRow-\(rows[0].setID)").firstMatch
        let secondRow = app.descendants(matching: .any).matching(identifier: "workoutSetRow-\(rows[1].setID)").firstMatch
        reveal(firstRow, in: app)
        firstRow.buttons["completeSet-1"].tap()
        let countdown = app.descendants(matching: .any)["restCountdown"]
        XCTAssertFalse(countdown.exists, "An Off exercise in a superset must not start a rest countdown")
        XCTAssertTrue(rest0.exists)

        reveal(secondRow, in: app)
        secondRow.buttons["completeSet-1"].tap()
        app.navigationBars.firstMatch.tap()
        XCTAssertTrue(countdown.waitForExistence(timeout: 5))
        let initialCountdown = countdown.label
        let expectedStartLabels = ["1:00"] + (55...59).map { "0:\($0)" }
        XCTAssertTrue(expectedStartLabels.contains(initialCountdown), "Expected a one-minute timer, found \(initialCountdown)")
        XCTAssertFalse(rest1.exists, "The active rest countdown replaces the static between-set rest indicator")
        let skip = app.buttons["skipRestButton"]
        reveal(skip, in: app)
        skip.tap()
        XCTAssertFalse(countdown.exists)
        XCTAssertTrue(rest1.waitForExistence(timeout: 5))

        relaunchAndResumeWorkout(app)
        reveal(rest0, in: app)
        XCTAssertTrue(rest0.label.contains("Off"))
        reveal(rest1, in: app)
        XCTAssertTrue(rest1.label.contains("Workout default (1:00)"))
    }

    @MainActor
    func testWorkoutSupersetSetsAlternateAndCompletionSurvivesRelaunch() {
        let app = launchFreshApp()
        defer { app.terminate() }
        beginTemplate(named: "Alternating Superset", in: app)
        addExercise("Bench Press", in: app)
        addExercise("Squat", in: app)
        app.buttons["saveTemplateButton"].tap()
        startNewestTemplate(in: app)
        for name in ["Bench Press", "Squat"] {
            let add = app.buttons["addSet-\(name)"]
            reveal(add, in: app)
            add.tap()
        }
        openSupersetEditor(for: "Bench Press", active: true, in: app)
        candidate("Squat", index: 2, in: app).tap()
        app.buttons["saveSupersetButton"].tap()

        func labels() -> [XCUIElement] {
            app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "supersetSetExercise-")).allElementsBoundByIndex
        }
        func orderedRows() -> [(id: String, name: String)] {
            var rows: [(id: String, name: String)] = []
            for _ in 0..<6 {
                for label in labels() where !rows.contains(where: { $0.id == label.identifier }) {
                    rows.append((label.identifier, label.label))
                }
                if rows.count == 4 { break }
                app.swipeUp()
            }
            return rows
        }
        let rows = orderedRows()
        XCTAssertEqual(rows.map(\.name), ["Bench Press", "Squat", "Bench Press", "Squat"])
        let firstID = String(rows[0].id.dropFirst("supersetSetExercise-".count))
        let secondID = String(rows[1].id.dropFirst("supersetSetExercise-".count))
        let firstRow = app.descendants(matching: .any).matching(identifier: "workoutSetRow-\(firstID)").firstMatch
        let secondRow = app.descendants(matching: .any).matching(identifier: "workoutSetRow-\(secondID)").firstMatch
        reveal(firstRow, in: app)
        attachScreenshot(named: "Merged superset alternates sets by round", in: app)
        firstRow.buttons["completeSet-1"].tap()
        XCTAssertEqual(firstRow.buttons["completeSet-1"].label, "Mark set 1 incomplete")
        reveal(secondRow, in: app)
        XCTAssertEqual(secondRow.buttons["completeSet-1"].label, "Complete set 1")
        if app.buttons["skipRestButton"].exists { app.buttons["skipRestButton"].tap() }
        relaunchAndResumeWorkout(app)
        reveal(firstRow, in: app)
        XCTAssertEqual(firstRow.buttons["completeSet-1"].label, "Mark set 1 incomplete")
        XCTAssertEqual(orderedRows().map(\.name), ["Bench Press", "Squat", "Bench Press", "Squat"])
        openSupersetEditor(for: "Bench Press", editing: true, active: true, in: app)
        app.buttons["removeSupersetButton"].tap()
        XCTAssertTrue(labels().isEmpty, "Removing the superset restores individual exercise sections")
    }

    @MainActor
    func testCreateCancelAndSaveSupersetPersistsIntoWorkoutAndActiveEdits() {
        let app = launchFreshApp()
        defer { app.terminate() }
        beginTemplate(named: "Superset Persistence", in: app)
        addExercise("Bench Press", in: app)
        addExercise("Squat", in: app)
        addExercise("Deadlift", in: app)

        openSupersetEditor(for: "Bench Press", in: app)
        let first = candidate("Bench Press", index: 1, in: app)
        let second = candidate("Squat", index: 2, in: app)
        let third = candidate("Deadlift", index: 3, in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.exists, "The picker must include every template exercise")
        XCTAssertTrue(third.exists)
        XCTAssertEqual(first.value as? String, "Selected, required")
        XCTAssertFalse(app.buttons["saveSupersetButton"].isEnabled, "A superset needs at least two entries")
        second.tap()
        XCTAssertEqual(second.value as? String, "Selected")
        XCTAssertTrue(app.buttons["saveSupersetButton"].isEnabled)
        attachScreenshot(named: "Superset multi-select with two entries selected", in: app)
        app.buttons["cancelSupersetButton"].tap()
        assertGroup(nil, exercise: "Bench Press", in: app)
        assertGroup(nil, exercise: "Squat", in: app)
        assertGroup(nil, exercise: "Deadlift", in: app)

        openSupersetEditor(for: "Bench Press", in: app)
        XCTAssertEqual(candidate("Squat", index: 2, in: app).value as? String, "Not selected", "Cancel must discard membership changes")
        candidate("Squat", index: 2, in: app).tap()
        app.buttons["saveSupersetButton"].tap()
        assertGroup("Superset A", exercise: "Bench Press", in: app)
        assertGroup("Superset A", exercise: "Squat", in: app)
        assertGroup(nil, exercise: "Deadlift", in: app)
        reveal(exerciseMenu("Bench Press", in: app), in: app)
        attachScreenshot(named: "Template exercises grouped as Superset A", in: app)
        app.buttons["saveTemplateButton"].tap()

        relaunch(app)
        openTemplateOptions(named: "Superset Persistence", action: "Plan Next Workout", in: app)
        XCTAssertFalse(app.buttons["saveTemplateButton"].isEnabled, "Reloading the saved grouping must not create a change")
        assertGroup("Superset A", exercise: "Bench Press", in: app)
        assertGroup("Superset A", exercise: "Squat", in: app)
        assertGroup(nil, exercise: "Deadlift", in: app)
        app.navigationBars["Plan Next Workout"].buttons["Cancel"].tap()
        startNewestTemplate(in: app)
        assertGroup("Superset A", exercise: "Bench Press", active: true, in: app)
        assertGroup("Superset A", exercise: "Squat", active: true, in: app)
        assertGroup(nil, exercise: "Deadlift", active: true, in: app)

        relaunchAndResumeWorkout(app)
        openSupersetEditor(for: "Bench Press", editing: true, active: true, in: app)
        XCTAssertEqual(candidate("Squat", index: 2, in: app).value as? String, "Selected")
        candidate("Deadlift", index: 3, in: app).tap()
        app.buttons["saveSupersetButton"].tap()
        relaunchAndResumeWorkout(app)
        let groupMenu = supersetMenu("Superset A", in: app)
        reveal(groupMenu, in: app)
        XCTAssertEqual(supersetNames(in: app).label, "Bench Press · Squat · Deadlift")
        XCTAssertEqual(supersetMenus(in: app).count, 1)
        XCTAssertFalse(exerciseMenu("Deadlift", active: true, in: app).exists)
        openSupersetEditor(for: "Bench Press", editing: true, active: true, in: app)
        app.buttons["removeSupersetButton"].tap()
        relaunchAndResumeWorkout(app)
        for exercise in ["Bench Press", "Squat", "Deadlift"] {
            assertGroup(nil, exercise: exercise, active: true, in: app)
        }
    }

    @MainActor
    func testSupersetOnlyChangesCreateVersionsAndMembershipEditsAndRemovalPersist() {
        let app = launchFreshApp()
        defer { app.terminate() }
        beginTemplate(named: "Superset Versions", in: app)
        for exercise in ["Bench Press", "Squat", "Deadlift"] { addExercise(exercise, in: app) }
        app.buttons["saveTemplateButton"].tap()

        openTemplateOptions(named: "Superset Versions", action: "Plan Next Workout", in: app)
        let save = app.buttons["saveTemplateButton"]
        XCTAssertFalse(save.isEnabled)
        openSupersetEditor(for: "Bench Press", in: app)
        candidate("Squat", index: 2, in: app).tap()
        app.buttons["saveSupersetButton"].tap()
        XCTAssertTrue(save.isEnabled, "Changing only superset membership must enable saving a version")
        XCTAssertEqual(save.label, "Save Version")
        save.tap()
        assertNewestVersion(2, in: app)

        openTemplateOptions(named: "Superset Versions", action: "Plan Next Workout", in: app)
        XCTAssertFalse(save.isEnabled)
        openSupersetEditor(for: "Bench Press", editing: true, in: app)
        XCTAssertEqual(candidate("Squat", index: 2, in: app).value as? String, "Selected")
        candidate("Squat", index: 2, in: app).tap()
        candidate("Deadlift", index: 3, in: app).tap()
        app.buttons["saveSupersetButton"].tap()
        assertGroup("Superset A", exercise: "Bench Press", in: app)
        assertGroup(nil, exercise: "Squat", in: app)
        assertGroup("Superset A", exercise: "Deadlift", in: app)
        XCTAssertTrue(save.isEnabled)
        save.tap()

        relaunch(app)
        assertNewestVersion(3, in: app)
        openTemplateOptions(named: "Superset Versions", action: "Plan Next Workout", in: app)
        assertGroup("Superset A", exercise: "Bench Press", in: app)
        assertGroup(nil, exercise: "Squat", in: app)
        assertGroup("Superset A", exercise: "Deadlift", in: app)
        openSupersetEditor(for: "Bench Press", editing: true, in: app)
        app.buttons["removeSupersetButton"].tap()
        XCTAssertTrue(save.isEnabled)
        XCTAssertEqual(save.label, "Save Version")
        save.tap()

        relaunch(app)
        assertNewestVersion(4, in: app)
        openTemplateOptions(named: "Superset Versions", action: "Plan Next Workout", in: app)
        XCTAssertFalse(save.isEnabled)
        for exercise in ["Bench Press", "Squat", "Deadlift"] {
            assertGroup(nil, exercise: exercise, in: app)
        }
    }

    @MainActor
    func testUngroupedRemovalKeepsSupersetSummary() {
        let app = launchFreshApp()
        defer { app.terminate() }
        beginTemplate(named: "Untouched Superset", in: app)
        for exercise in ["Deadlift", "Bench Press", "Squat"] { addExercise(exercise, in: app) }
        openSupersetEditor(for: "Bench Press", in: app)
        candidate("Squat", index: 3, in: app).tap()
        app.buttons["saveSupersetButton"].tap()
        app.buttons["saveTemplateButton"].tap()

        openTemplateOptions(named: "Untouched Superset", action: "Plan Next Workout", in: app)
        let remove = app.buttons["Remove Deadlift"]
        reveal(remove, in: app)
        remove.tap()
        let save = app.buttons["saveTemplateButton"]
        XCTAssertTrue(save.isEnabled)
        XCTAssertEqual(save.label, "Save Version")
        let removalSummary = app.staticTexts["Remove Deadlift"]
        for _ in 0..<6 {
            if removalSummary.exists && removalSummary.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(removalSummary.isHittable)
        XCTAssertFalse(app.staticTexts["Update superset groups"].exists,
                       "Removing an ungrouped entry must not report a change to untouched superset members")
        attachScreenshot(named: "Only removed exercise appears in change summary", in: app)
        save.tap()
        relaunch(app)
        assertNewestVersion(2, in: app)
        openTemplateOptions(named: "Untouched Superset", action: "Plan Next Workout", in: app)
        XCTAssertFalse(save.isEnabled)
        assertGroup("Superset A", exercise: "Bench Press", in: app)
        assertGroup("Superset A", exercise: "Squat", in: app)
    }

    @MainActor
    func testRecreatingOriginalSupersetDiscardsVersionChange() {
        let app = launchFreshApp()
        defer { app.terminate() }
        beginTemplate(named: "Restored Superset", in: app)
        addExercise("Bench Press", in: app)
        addExercise("Squat", in: app)
        openSupersetEditor(for: "Bench Press", in: app)
        candidate("Squat", index: 2, in: app).tap()
        app.buttons["saveSupersetButton"].tap()
        app.buttons["saveTemplateButton"].tap()

        openTemplateOptions(named: "Restored Superset", action: "Plan Next Workout", in: app)
        let save = app.buttons["saveTemplateButton"]
        XCTAssertFalse(save.isEnabled)
        openSupersetEditor(for: "Bench Press", editing: true, in: app)
        app.buttons["removeSupersetButton"].tap()
        XCTAssertTrue(save.isEnabled)
        XCTAssertEqual(save.label, "Save Version")
        let summary = app.staticTexts["Update superset groups"]
        reveal(summary, in: app)
        attachScreenshot(named: "Removed superset enables Save Version", in: app)

        openSupersetEditor(for: "Bench Press", in: app)
        candidate("Squat", index: 2, in: app).tap()
        app.buttons["saveSupersetButton"].tap()
        XCTAssertFalse(save.isEnabled, "Restoring the original members is not a prescription change")
        XCTAssertEqual(save.label, "Save")
        let unchanged = app.staticTexts["Adjust a weight, rep target, exercise, superset, or rest period to create your next version."]
        reveal(unchanged, in: app)
        XCTAssertFalse(summary.exists, "The summary must use the same membership comparison as saving")
        attachScreenshot(named: "Restored superset disables Save and clears changes", in: app)

        addExercise("Deadlift", in: app)
        XCTAssertTrue(save.isEnabled)
        XCTAssertEqual(save.label, "Save Version")
        reveal(app.staticTexts["Add Deadlift: 1 sets"], in: app)
        XCTAssertFalse(summary.exists, "Adding an ungrouped exercise must not report a superset edit")
        let remove = app.buttons["Remove Deadlift"]
        reveal(remove, in: app)
        remove.tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed,
                       "Undoing the added exercise restores the saved prescription")

        let name = app.textFields["templateNameField"]
        reveal(name, in: app)
        name.tap()
        name.typeText(" Renamed")
        app.buttons["Done"].tap()
        XCTAssertTrue(save.isEnabled)
        XCTAssertEqual(save.label, "Save", "Renaming after undoing a group edit must not create a version")
        save.tap()
        relaunch(app)
        assertNewestVersion(1, in: app)
        openTemplateOptions(named: "Restored Superset Renamed", action: "Plan Next Workout", in: app)
        XCTAssertFalse(save.isEnabled)
        assertGroup("Superset A", exercise: "Bench Press", in: app)
        assertGroup("Superset A", exercise: "Squat", in: app)
    }

    @MainActor
    func testDuplicateExerciseEntriesCanBeSelectedIndependently() {
        let app = launchFreshApp()
        defer { app.terminate() }
        beginTemplate(named: "Duplicate Superset Entries", in: app)
        addExercise("Bench Press", in: app)
        addExercise("Bench Press", in: app)
        addExercise("Squat", in: app)
        openSupersetEditor(for: "Bench Press", in: app)
        let first = candidate("Bench Press", index: 1, in: app)
        let duplicate = candidate("Bench Press", index: 2, in: app)
        XCTAssertNotEqual(first.identifier, duplicate.identifier, "Membership must use entry identities, even when the catalog exercise is identical")
        XCTAssertEqual(first.value as? String, "Selected, required")
        XCTAssertEqual(duplicate.value as? String, "Not selected")
        duplicate.tap()
        XCTAssertEqual(first.value as? String, "Selected, required")
        XCTAssertEqual(duplicate.value as? String, "Selected")
        app.buttons["saveSupersetButton"].tap()
        assertGroup("Superset A", exercise: "Bench Press", occurrence: 0, in: app)
        assertGroup("Superset A", exercise: "Bench Press", occurrence: 1, in: app)
        assertGroup(nil, exercise: "Squat", in: app)
        app.buttons["saveTemplateButton"].tap()
        relaunch(app)
        openTemplateOptions(named: "Duplicate Superset Entries", action: "Plan Next Workout", in: app)
        assertGroup("Superset A", exercise: "Bench Press", occurrence: 0, in: app)
        assertGroup("Superset A", exercise: "Bench Press", occurrence: 1, in: app)
        assertGroup(nil, exercise: "Squat", in: app)
    }

    @MainActor
    private func attachScreenshot(named name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
    private func beginTemplate(named name: String, in app: XCUIApplication) {
        app.buttons["createTemplateButton"].tap()
        let field = app.textFields["templateNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        app.buttons["Done"].tap()
    }

    @MainActor
    private func addExercise(_ name: String, in app: XCUIApplication) {
        let add = app.buttons["addExerciseButton"]
        reveal(add, in: app)
        add.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let exercise = app.buttons["exercise-\(name)"]
        if !exercise.isHittable {
            search.tap()
            search.typeText(name)
        }
        XCTAssertTrue(exercise.waitForExistence(timeout: 5))
        exercise.tap()
        XCTAssertTrue(app.buttons["saveTemplateButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func candidate(_ name: String, index: Int, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier BEGINSWITH %@", "\(name), exercise \(index)", "supersetExercise-")).firstMatch
    }

    @MainActor
    private func exerciseMenu(_ name: String, occurrence: Int = 0, active: Bool = false, in app: XCUIApplication) -> XCUIElement {
        let label = active ? "Options for \(name)" : "Exercise options for \(name)"
        return app.buttons.matching(NSPredicate(format: "label == %@ AND identifier BEGINSWITH %@", label, active ? "workoutExerciseMenu-" : "templateExerciseMenu-")).element(boundBy: occurrence)
    }

    @MainActor
    private func supersetMenus(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workoutSupersetMenu-'"))
    }

    @MainActor
    private func supersetMenu(_ label: String, in app: XCUIApplication) -> XCUIElement {
        supersetMenus(in: app).matching(NSPredicate(format: "label == %@", "Options for \(label)")).firstMatch
    }

    @MainActor
    private func supersetNames(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'workoutSupersetNames-'")).firstMatch
    }

    @MainActor
    private func openSupersetEditor(for name: String, editing: Bool = false, active: Bool = false, in app: XCUIApplication) {
        let menu = active && editing ? supersetMenu("Superset A", in: app) : exerciseMenu(name, active: active, in: app)
        reveal(menu, in: app)
        menu.tap()
        let action = app.buttons[editing ? "editSupersetButton" : "addSupersetButton"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
        XCTAssertTrue(app.buttons["saveSupersetButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func assertGroup(_ label: String?, exercise: String, occurrence: Int = 0, active: Bool = false, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        if active, let label {
            let menu = supersetMenu(label, in: app)
            reveal(menu, in: app)
            XCTAssertTrue(supersetNames(in: app).label.components(separatedBy: " · ").contains(exercise), file: file, line: line)
            XCTAssertFalse(exerciseMenu(exercise, active: true, in: app).exists, file: file, line: line)
            return
        }
        let menu = exerciseMenu(exercise, occurrence: occurrence, active: active, in: app)
        reveal(menu, in: app)
        if active { return }
        let entryID = String(menu.identifier.dropFirst("templateExerciseMenu-".count))
        let group = app.descendants(matching: .any).matching(identifier: "supersetLabel-\(entryID)").firstMatch
        if let label {
            XCTAssertTrue(group.waitForExistence(timeout: 5), file: file, line: line)
            XCTAssertEqual(group.label, label, file: file, line: line)
        } else {
            XCTAssertFalse(group.exists, "\(exercise) should be ungrouped", file: file, line: line)
        }
    }

    @MainActor
    private func openTemplateOptions(named name: String, action: String, in app: XCUIApplication) {
        let options = app.buttons["Options for \(name)"]
        reveal(options, in: app)
        options.tap()
        // Exclude the identically titled action on the template card behind the menu.
        let item = app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier BEGINSWITH %@)", action, "planTemplate-")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(app.buttons["saveTemplateButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func startNewestTemplate(in app: XCUIApplication) {
        let start = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "startTemplate-")).allElementsBoundByIndex.last!
        reveal(start, in: app)
        start.tap()
        XCTAssertTrue(app.buttons["finishWorkoutButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func assertNewestVersion(_ number: Int, in app: XCUIApplication) {
        let version = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "currentTemplateVersion-")).allElementsBoundByIndex.last!
        reveal(version, in: app)
        XCTAssertEqual(version.label, "Version \(number) · Default")
    }

    @MainActor
    private func relaunch(_ app: XCUIApplication) {
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["createTemplateButton"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func relaunchAndResumeWorkout(_ app: XCUIApplication) {
        relaunch(app)
        let resume = app.buttons["resumeWorkoutButton"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        XCTAssertTrue(app.buttons["finishWorkoutButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func setUseWorkoutDefault(_ enabled: Bool, in app: XCUIApplication) {
        let toggle = app.switches["useWorkoutRestDefault"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if (toggle.value as? String == "1") != enabled {
            let control = toggle.switches.firstMatch
            (control.exists ? control : toggle).tap()
        }
    }

    @MainActor
    private func assertRestBetween(_ rest: XCUIElement, afterSetID: String, beforeSetID: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let before = app.descendants(matching: .any).matching(identifier: "workoutSetRow-\(afterSetID)").firstMatch
        let after = app.descendants(matching: .any).matching(identifier: "workoutSetRow-\(beforeSetID)").firstMatch
        reveal(after, in: app)
        XCTAssertTrue(rest.exists && before.exists && after.exists, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rest.frame.minY, before.frame.maxY - 2, file: file, line: line)
        XCTAssertLessThanOrEqual(rest.frame.maxY, after.frame.minY + 2, file: file, line: line)
    }

    @MainActor
    private func isClearOfChrome(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists && element.isHittable else { return false }
        let navBar = app.navigationBars.allElementsBoundByIndex.last { $0.exists && !$0.frame.isEmpty }
        let minY = navBar?.frame.maxY ?? 0
        guard element.frame.minY >= minY else { return false }
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists && tabBar.isHittable && !tabBar.frame.isEmpty {
            return element.frame.maxY <= tabBar.frame.minY
        }
        return true
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        if isClearOfChrome(element, in: app) { return }
        // Exercise section headers and the newly appended template can start offscreen
        // or sit beneath the translucent navigation bar or tab bar.
        for _ in 0..<6 {
            app.swipeDown()
            if isClearOfChrome(element, in: app) { return }
        }
        for _ in 0..<10 {
            app.swipeUp()
            if isClearOfChrome(element, in: app) { return }
        }
        XCTAssertTrue(element.exists, "Expected control was not found: \(element)")
        XCTAssertTrue(element.isHittable, "Expected control could not be scrolled into view: \(element)")
    }
}
