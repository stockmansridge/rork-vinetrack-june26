import XCTest

final class KeyboardInteractionUITests: XCTestCase {
    @MainActor
    func testDoneAcrossKeyboardTypesKeepsValuesWithoutSavingOrSubmitting() {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation"]
        app.launch()
        let samples: [(String, String)] = [("text", "Draft"), ("number", "125"), ("decimal", "12.5"),
            ("email", "a@example.com"), ("url", "https://example.com"), ("phone", "123456"),
            ("search", "vines"), ("password", "secret12"), ("multiline", "Draft note"), ("native", "Native draft"), ("formatted", "25.75")]
        for (kind, value) in samples {
            let field = kind == "password" ? app.secureTextFields["input.\(kind)"] : app.textFields["input.\(kind)"]
            for _ in 0..<5 where !field.isHittable { app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(field.waitForExistence(timeout: 5), kind)
            field.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), kind)
            if kind == "formatted" { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4)) }
            field.typeText(value)
            let done = app.buttons["keyboard.dismiss"]
            XCTAssertTrue(done.waitForExistence(timeout: 5), kind)
            done.tap()
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, kind)
            if kind != "password" { XCTAssertEqual(field.value as? String, value, kind) }
        }
        XCTAssertEqual(app.staticTexts["keyboard.counters"].label, "Submits: 0; Saves: 0")
    }

    @MainActor
    func testPassiveTapAndInteractiveScrollDismissWithoutSubmitting() {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation"]
        app.launch()
        let text = app.textFields["input.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap(); text.typeText("Unsaved")
        app.staticTexts["keyboard.background"].tap()
        var hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, "Passive content tap must dismiss")
        XCTAssertEqual(text.value as? String, "Unsaved")
        text.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertLessThan(app.staticTexts["keyboard.background"].frame.maxY, app.keyboards.firstMatch.frame.minY)
        let dragStart = app.staticTexts["keyboard.background"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let dragEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
        hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, "Scroll-down must dismiss")
        XCTAssertEqual(text.value as? String, "Unsaved")
        XCTAssertEqual(app.staticTexts["keyboard.counters"].label, "Submits: 0; Saves: 0")
    }

    @MainActor
    func testSheetFullScreenAndNestedListReceiveAccessoryWithoutRootToolbarInheritance() {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation"]
        app.launch()
        for presentation in ["Sheet", "Full screen", "List"] {
            let open = app.buttons[presentation]
            XCTAssertTrue(open.waitForExistence(timeout: 5))
            open.tap()
            let prefix = presentation == "Sheet" ? "sheet" : presentation == "Full screen" ? "full" : "list"
            let number = app.textFields["input.\(prefix).number"]
            XCTAssertTrue(number.waitForExistence(timeout: 5))
            for _ in 0..<4 where !number.isHittable { app.swipeUp() }
            number.tap(); number.typeText("42")
            let done = app.buttons["keyboard.dismiss"]
            XCTAssertTrue(done.waitForExistence(timeout: 5), presentation)
            done.tap()
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, presentation)
            XCTAssertEqual(number.value as? String, "42", presentation)
            if presentation == "List" {
                let search = app.searchFields.firstMatch
                XCTAssertTrue(search.waitForExistence(timeout: 5))
                search.tap(); search.typeText("Block draft")
                XCTAssertTrue(done.waitForExistence(timeout: 5), "Native searchable accessory")
                done.tap()
                XCTAssertEqual(search.value as? String, "Block draft")
                let searchClose = app.buttons["Close"]
                XCTAssertTrue(searchClose.waitForExistence(timeout: 5), "Native search exit remains available")
                searchClose.tap()
            } else { app.buttons["keyboard.\(prefix).close"].tap() }
        }
    }

    @MainActor
    func testBottomMultilineEditorIsVisibleAndControlsRetainTheirActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation", "--keyboard-large-text"]
        app.launch()
        let editor = app.textViews["input.editor"]
        for _ in 0..<5 where !editor.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); editor.typeText("Line one\nLine two")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertLessThan(editor.frame.minY, keyboard.frame.minY)
        app.buttons["keyboard.dismiss"].tap()
        XCTAssertEqual(editor.value as? String, "Line one\nLine two")
        let bottom = app.textFields["input.bottom"]
        for _ in 0..<5 where !bottom.isHittable { app.scrollViews.firstMatch.swipeUp() }
        bottom.tap(); bottom.typeText("Bottom draft")
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(bottom.frame.maxY, keyboard.frame.minY)
        app.buttons["keyboard.dismiss"].tap()
        XCTAssertEqual(bottom.value as? String, "Bottom draft")
        app.switches["keyboard.toggle"].tap()
        app.buttons["keyboard.save"].tap()
        XCTAssertEqual(app.staticTexts["keyboard.counters"].label, "Submits: 0; Saves: 1")
    }

    @MainActor
    func testFocusTransferAndAlertDraftDismissalDoNotSubmit() {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation"]
        app.launch()
        let text = app.textFields["input.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap(); text.typeText("Draft")
        let number = app.textFields["input.number"]
        number.tap(); number.typeText("42")
        let done = app.buttons["keyboard.dismiss"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertEqual(text.value as? String, "Draft")
        XCTAssertEqual(number.value as? String, "42")
        app.buttons["keyboard.alert"].tap()
        let popup = app.alerts["Keyboard popup"]
        XCTAssertTrue(popup.waitForExistence(timeout: 5))
        let draft = popup.textFields.firstMatch
        draft.tap(); draft.typeText("Popup draft")
        XCTAssertTrue(done.waitForExistence(timeout: 5), "App-owned alert text control")
        done.tap()
        XCTAssertTrue(popup.exists, "Done must not confirm or cancel the popup")
        XCTAssertEqual(draft.value as? String, "Popup draft")
        popup.buttons["Cancel"].tap()
        XCTAssertEqual(app.staticTexts["keyboard.counters"].label, "Submits: 0; Saves: 0")
    }
}
