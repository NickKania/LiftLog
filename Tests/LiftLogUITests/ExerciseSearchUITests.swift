import XCTest

/// Search suggestions are explicit offline choices and retain the user's query.
final class ExerciseSearchUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testAliasesTyposAndMetadataFiltersPreserveExplicitCustomCreation() {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["createTemplateButton"].waitForExistence(timeout: 10))
        app.buttons["createTemplateButton"].tap()
        tap("addExerciseButton", in: app)

        search("OHP", in: app)
        XCTAssertTrue(app.buttons["exercise-Overhead Press"].waitForExistence(timeout: 5))
        XCTAssertTrue(reason(containing: "Also known as", in: app).exists)
        XCTAssertFalse(app.staticTexts["exercisePossibleMatchesNotice"].exists)
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "OHP")
        keepScreenshot(of: app, named: "Alias OHP finds Overhead Press without rewriting query")

        search("Bnech Press", in: app)
        XCTAssertTrue(app.buttons["exercise-Bench Press"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["exercisePossibleMatchesNotice"].exists)
        XCTAssertTrue(reason(containing: "Similar spelling", in: app).exists)
        let createCustom = app.buttons["addCustomExerciseButton"]
        reveal(createCustom, in: app)
        XCTAssertTrue(createCustom.isHittable, "A suggested spelling must not remove explicit custom creation")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "Bnech Press")
        keepScreenshot(of: app, named: "Possible Bench Press match and explicit custom creation")

        setEquipment("Dumbbell", in: app)
        XCTAssertFalse(app.buttons["exercise-Bench Press"].exists, "Fuzzy matches must obey the metadata filter")
        tap("clearExerciseFiltersButton", in: app)
        XCTAssertTrue(app.buttons["exercise-Bench Press"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "Bnech Press", "Clearing filters preserves the typed query")
        search("", in: app)
        XCTAssertFalse(app.staticTexts["exercisePossibleMatchesNotice"].exists)
        XCTAssertTrue(app.buttons["exercise-Squat"].waitForExistence(timeout: 5))

        let customName = "Search Fixture Sled Drag"
        search(customName, in: app)
        XCTAssertTrue(app.staticTexts["No matching exercises"].waitForExistence(timeout: 5))
        tap("addCustomExerciseButton", in: app)
        XCTAssertTrue(app.buttons["Remove \(customName)"].waitForExistence(timeout: 5))
        let name = app.textFields["templateNameField"]
        reveal(name, in: app, upward: false)
        name.tap()
        name.typeText("Search Custom Persistence")
        app.buttons["Done"].tap()
        app.buttons["saveTemplateButton"].tap()
        XCTAssertTrue(app.buttons["createTemplateButton"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["createTemplateButton"].waitForExistence(timeout: 10))
        app.buttons["createTemplateButton"].tap()
        tap("addExerciseButton", in: app)
        search(customName, in: app)
        XCTAssertTrue(app.buttons["exercise-\(customName)"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["addCustomExerciseButton"].exists)
        XCTAssertFalse(app.staticTexts["exercisePossibleMatchesNotice"].exists)
    }

    @MainActor
    private func reason(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "exerciseSearchReason-", text)).firstMatch
    }

    @MainActor
    private func setEquipment(_ equipment: String, in app: XCUIApplication) {
        tap("exerciseFilterButton", in: app)
        XCTAssertTrue(app.buttons["exerciseFiltersDoneButton"].waitForExistence(timeout: 5))
        tap("exerciseEquipmentFilter", in: app)
        let option = app.buttons[equipment].firstMatch
        reveal(option, in: app)
        option.tap()
        tap("exerciseFiltersDoneButton", in: app)
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
        if !text.isEmpty {
            field.typeText(text)
            XCTAssertEqual(field.value as? String, text)
        }
        field.typeText("\n")
    }

    @MainActor
    private func tap(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        reveal(button, in: app)
        button.tap()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = true) {
        if element.isHittable { return }
        for _ in 0..<15 {
            if upward { app.swipeUp() } else { app.swipeDown() }
            if element.isHittable { return }
        }
        for _ in 0..<15 {
            if upward { app.swipeDown() } else { app.swipeUp() }
            if element.isHittable { return }
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
