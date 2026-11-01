import XCTest

final class SprayEditingAcceptanceUITests: XCTestCase {
    @MainActor private func replace(_ field: XCUIElement, with text: String, app: XCUIApplication) {
        field.tap()
        if let value = field.value as? String, !value.isEmpty {
            field.press(forDuration: 1.2)
            let selectAll = app.menuItems["Select All"]
            XCTAssertTrue(selectAll.waitForExistence(timeout: 3), "Whole-field replacement menu")
            selectAll.tap()
        }
        field.typeText(text)
    }

    @MainActor func testConfiguredByAreaReviewReachesEnabledStartInSameCalculator() {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation", "--spray-calculator-keyboard-validation", "--spray-regional-validation", "--spray-direct-start-validation"]
        app.launch()
        let open = app.buttons["Open Spray Calculator"]
        XCTAssertTrue(open.waitForExistence(timeout: 8)); open.tap()
        let review = app.buttons["spray.reviewTankMix"]
        for _ in 0..<18 where !review.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(review.waitForExistence(timeout: 8))
        XCTAssertTrue(review.isEnabled)
        review.tap()
        let start = app.buttons["spray.startTrip"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(start.isEnabled, "Calculated quantities alone cannot become actual-use records")
        let water = app.textFields["spray.actualWater"]
        let chemical = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "spray.actualChemical.")).firstMatch
        for _ in 0..<12 where !water.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(water.waitForExistence(timeout: 5))
        XCTAssertTrue(water.isEnabled, "Actual water must be editable before selecting a path")
        XCTAssertTrue(["", "Enter amount"].contains(water.value as? String ?? ""), "Calculated water is a guide, not pre-entered actuals")
        water.tap(); water.typeText("875.5")
        app.buttons["keyboard.dismiss"].tap()
        XCTAssertFalse(start.isEnabled, "Water alone cannot substitute for the chemical actually loaded")
        for _ in 0..<8 where !chemical.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(chemical.waitForExistence(timeout: 5))
        XCTAssertTrue(chemical.isEnabled, "Chemical amounts must be editable before selecting a path")
        XCTAssertTrue(["", "Enter amount"].contains(chemical.value as? String ?? ""))
        chemical.tap(); chemical.typeText("637.25")
        app.buttons["keyboard.dismiss"].tap()
        XCTAssertEqual(water.value as? String, "875.5")
        XCTAssertEqual(chemical.value as? String, "637.25")
        XCTAssertTrue(start.isEnabled, "Explicit actual quantities satisfy the mix gate independently of path selection")

        // Choose a route only AFTER entering different-from-calculated amounts.
        // This guards the reported ordering failure and any rebuild that erases
        // actual text when a route selection invalidates the View body.
        let pattern = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "One After Another")).firstMatch
        for _ in 0..<12 where !pattern.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(pattern.isHittable); pattern.tap()
        let startPath = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Start path")).firstMatch
        for _ in 0..<12 where !startPath.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(startPath.isHittable); startPath.tap()
        let chosenPath = app.buttons["Synthetic regional block · Path 1.5"]
        XCTAssertTrue(chosenPath.waitForExistence(timeout: 5)); chosenPath.tap()
        for _ in 0..<12 where !water.isHittable { app.scrollViews.firstMatch.swipeDown() }
        XCTAssertEqual(water.value as? String, "875.5", "Selecting a path must retain actual water")
        XCTAssertEqual(chemical.value as? String, "637.25", "Selecting a path must retain actual chemical amount")
        for _ in 0..<12 where !start.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(start.isEnabled, "Entered valid mix starts without acknowledging advisory warnings")
        let warnings = app.buttons.matching(identifier: "spray.concentrationWarning")
        guard let warning = warnings.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("Optional orange CF warning must be visible beside enabled Start in Mixing: \(app.debugDescription)")
            return
        }
        warning.tap()
        XCTAssertTrue(app.navigationBars["Concentration / Label Warning"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        XCTAssertTrue(start.isEnabled, "Opening or dismissing the optional warning never changes admission")
        // No real account/receipt transport is installed in this isolated presentation fixture.
        app.buttons["Cancel"].firstMatch.tap()
        for _ in 0..<12 where !review.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(review.isEnabled, "Cancel keeps the same configured mix available")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertEqual(app.staticTexts["spray.keyboard.records"].label, "Sprays: 0; Trips: 0")
    }

    @MainActor func testProductionChemicalCardRetainsExactDraftAndRejectsInvalidPreviousDose() {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation", "--spray-chemical-editing-validation"]
        app.launch()
        XCTAssertTrue(app.staticTexts["chemical.validation.ready"].waitForExistence(timeout: 8))
        let field = app.textFields["applicationRateField"]
        for (raw, base) in [("25.75", "25750.0"), ("0.75", "750.0"), ("1250.5", "1250500.0"),
                            ("25,75", "25750.0"), ("0,75", "750.0"), ("1250,5", "1250500.0"),
                            (".", "0.0"), ("25,7.5", "0.0")] {
            replace(field, with: raw, app: app)
            XCTAssertEqual(field.value as? String, raw, "Visible original entry before dismissal")
            XCTAssertEqual(app.staticTexts["chemical.validation.base"].label, base, "Production callback effective base rate")
            XCTAssertEqual(app.staticTexts["chemical.validation.raw"].label, raw)
            let done = app.buttons["keyboard.dismiss"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            done.tap()
            XCTAssertEqual(field.value as? String, raw)
            app.buttons["Reopen card"].tap()
            app.buttons["Reopen card"].tap()
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertEqual(field.value as? String, raw, "Card reconstruction retains original draft")
            if base == "0.0" { XCTAssertTrue(app.otherElements["applicationRateRejection"].exists || app.staticTexts["applicationRateRejection"].exists) }
        }
        app.buttons["Confirmed rate"].tap()
        XCTAssertEqual(app.staticTexts["chemical.validation.base"].label, "nil")
    }

    @MainActor func testProductionStepSixLiveUnitsPreserveCanonicalValuesAndControllerOnlyConfiguration() {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation", "--spray-calculator-keyboard-validation", "--spray-regional-validation"]
        app.launch()
        let open = app.buttons["Open Spray Calculator"]
        XCTAssertTrue(open.waitForExistence(timeout: 8)); open.tap()
        let canonical = app.staticTexts["spray.regional.canonical"]
        let stepSixExists = canonical.waitForExistence(timeout: 8)
        let prerequisites = app.staticTexts["spray.regional.prerequisites"].label
        XCTAssertTrue(stepSixExists, "Production Step6 prerequisites: \(prerequisites)")
        guard stepSixExists else { return }
        XCTAssertEqual(canonical.label, "litres=600.000000 ha=1.000000 travel=16.800000")
        app.buttons["Over-Row"].tap()
        XCTAssertEqual(canonical.label, "litres=600.000000 ha=1.000000 travel=33.600000")
        app.buttons["Switch units"].tap()
        XCTAssertEqual(canonical.label, "litres=600.000000 ha=1.000000 travel=33.600000")
        app.buttons["Switch units"].tap()
        let tank = app.textFields["spray.planning.tank"]
        for _ in 0..<5 where !tank.isHittable { app.scrollViews.firstMatch.swipeUp() }
        replace(tank, with: ".", app: app)
        app.buttons["keyboard.dismiss"].tap()
        app.buttons["Switch units"].tap()
        XCTAssertTrue(app.staticTexts["spray.planning.unitsHeld"].waitForExistence(timeout: 5))
        XCTAssertEqual(tank.value as? String, ".")
        XCTAssertEqual(canonical.label, "litres=-1.000000 ha=1.000000 travel=-1.000000")
    }
}
