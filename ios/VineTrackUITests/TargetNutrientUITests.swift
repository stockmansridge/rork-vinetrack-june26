import XCTest

final class TargetNutrientUITests: XCTestCase {
    @MainActor private func show(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            if element.exists && element.frame.midY < app.frame.midY { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.exists)
    }
    @MainActor private func launch(nonAdmin: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation", "--target-nutrient-validation"] + (nonAdmin ? ["--nutrient-non-admin"] : [])
        app.launch()
        XCTAssertTrue(app.navigationBars["Target Nutrient fixture"].waitForExistence(timeout: 8))
        return app
    }
    @MainActor private func enter(_ id: String, _ value: String, app: XCUIApplication) {
        let field = app.textFields[id]; show(field, app: app); field.tap(); field.typeText(value)
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
    }
    @MainActor func testPhoneLiveResultsImmediatelyFollowInputsAndCannotSave() {
        let app = launch()
        enter("nutrient.percent", "16", app: app)
        enter("nutrient.target", "2", app: app)
        enter("nutrient.vines", "1000", app: app)
        let rate = app.staticTexts["nutrient.rate"]
        show(rate, app: app)
        XCTAssertEqual(rate.label.replacingOccurrences(of: ",", with: "."), "12.5 g/vine")
        XCTAssertEqual(app.staticTexts["nutrient.total"].label.replacingOccurrences(of: ",", with: "."), "12.5 kg")
        XCTAssertEqual(app.staticTexts["nutrient.delivered"].label, "2 kg")
        let details = app.staticTexts["nutrient.blockDetails"]
        XCTAssertLessThan(rate.frame.minY, details.frame.minY)
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Target nutrient — production phone preview, synthetic quantities"; capture.lifetime = .keepAlways; add(capture)
        let save = app.buttons["nutrient.saveDisabled"]; show(save, app: app); XCTAssertFalse(save.isEnabled)
        XCTAssertFalse(app.buttons["Add Nutrient"].exists)
    }
    @MainActor func testNutrientSwitchRetainsPercentAndTarget() {
        let app = launch()
        enter("nutrient.percent", "20", app: app)
        enter("nutrient.target", "2", app: app)
        for _ in 0..<4 { app.swipeDown() }
        let picker = app.buttons["nutrient.selection"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3)); picker.tap()
        app.buttons["Ca — Calcium"].tap()
        XCTAssertEqual(app.textFields["nutrient.percent"].value as? String, "20")
        show(app.textFields["nutrient.target"], app: app)
        XCTAssertEqual(app.textFields["nutrient.target"].value as? String, "2")
        XCTAssertFalse(app.staticTexts["nutrient.rate"].exists)
    }
    @MainActor func testLiquidConcentrationAndBlockCountsDriveLiveResults() {
        let app = launch()
        app.switches["Liquid product"].tap()
        enter("nutrient.percent", "16", app: app)
        enter("nutrient.target", "2", app: app)
        enter("nutrient.vines", "1000", app: app)
        XCTAssertFalse(app.staticTexts["nutrient.rate"].exists)
        for _ in 0..<4 { app.swipeDown() }
        let basis = app.buttons["nutrient.concentration"]; show(basis, app: app); basis.tap()
        app.buttons["w/v — weight / volume"].tap()
        show(app.staticTexts["nutrient.rate"], app: app)
        XCTAssertEqual(app.staticTexts["nutrient.rate"].label.replacingOccurrences(of: ",", with: "."), "12.5 mL/vine")
        let block = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Synthetic A")).firstMatch
        show(block, app: app); block.tap()
        show(app.staticTexts["nutrient.total"], app: app)
        XCTAssertEqual(app.staticTexts["nutrient.total"].label.replacingOccurrences(of: ",", with: "."), "52.5 L")
        let assumed = app.buttons["Assumed full"]; show(assumed, app: app); assumed.tap()
        show(app.staticTexts["nutrient.total"], app: app)
        XCTAssertEqual(app.staticTexts["nutrient.total"].label.replacingOccurrences(of: ",", with: "."), "62.5 L")
    }
    @MainActor func testNonAdminCannotMountPreview() {
        let app = launch(nonAdmin: true)
        XCTAssertTrue(app.staticTexts["Target Nutrient is not enabled for this account."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["nutrient.percent"].exists)
        XCTAssertFalse(app.buttons["nutrient.saveDisabled"].exists)
    }
}
