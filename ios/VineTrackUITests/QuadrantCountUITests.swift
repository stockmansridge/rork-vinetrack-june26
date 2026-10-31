import XCTest

final class QuadrantCountUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }
    @MainActor private func launch(admin: Bool, extra: [String] = [], reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation", "--yield-trip-validation", "--quadrant-validation"]
            + (admin ? ["--yield-admin"] : []) + (reset ? ["--reset-yield-trip"] : []) + extra
        app.launch()
        XCTAssertTrue(app.navigationBars["Bunch Count Trips"].waitForExistence(timeout: 10))
        return app
    }
    @MainActor private func reveal(_ item: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<7 {
            if item.exists && item.isHittable { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.85))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.2))
            start.press(forDuration: 0.01, thenDragTo: end)
        }
        XCTAssertTrue(item.exists && item.isHittable, "Cannot reveal \(item.identifier): \(app.debugDescription)")
    }
    @MainActor private func startQuadrant(_ app: XCUIApplication) {
        let start = app.buttons["Start Bunch Count Trip"]; reveal(start, in: app); start.tap()
        let option = app.buttons["2. Quadrant Count"]; XCTAssertTrue(option.waitForExistence(timeout: 4)); option.tap()
        XCTAssertTrue(app.navigationBars["Quadrant Count"].waitForExistence(timeout: 4))
        app.buttons["Select All"].tap()
        let reuse = app.buttons["Use Existing Route (2 sites)"]; reveal(reuse, in: app); reuse.tap()
        if app.alerts["Trip not saved"].waitForExistence(timeout: 1) { app.alerts.buttons["OK"].tap() }
        let sampling = app.buttons["Start Sampling"]; reveal(sampling, in: app); sampling.tap()
        XCTAssertTrue(app.navigationBars["Guided Sampling"].waitForExistence(timeout: 6), "Guided screen did not open: \(app.debugDescription)")
        if app.alerts.buttons["Allow Once"].waitForExistence(timeout: 1) { app.alerts.buttons["Allow Once"].tap() }
    }
    @MainActor private func enter(_ value: String, field: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Missing field \(field.identifier)")
        field.tap()
        if let old = field.value as? String, Double(old) != nil {
            // Match the existing native editing tests: replace the whole value,
            // independent of where tapping a trailing-aligned field puts its caret.
            field.press(forDuration: 1.2)
            let selectAll = app.menuItems["Select All"]
            XCTAssertTrue(selectAll.waitForExistence(timeout: 3), "Cannot select existing \(field.identifier) value: \(old)")
            selectAll.tap()
        }
        field.typeText(value)
        XCTAssertEqual(field.value as? String, value, "Replacement did not reach \(field.identifier)")
    }
    @MainActor func testNonAdminNormalStartKeepsOriginalFullVinePath() {
        let app = launch(admin: false)
        let start = app.buttons["Start Bunch Count Trip"]; reveal(start, in: app); start.tap()
        XCTAssertTrue(app.navigationBars["Bunch Count Trip"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["2. Quadrant Count"].exists)
        XCTAssertFalse(app.textFields["yield.quadrant.count"].exists)
    }
    @MainActor func testAdminNormalStartOffersBothMethodsAndFullVineIsUnchanged() {
        let app = launch(admin: true)
        let start = app.buttons["Start Bunch Count Trip"]; reveal(start, in: app); start.tap()
        XCTAssertTrue(app.buttons["2. Quadrant Count"].waitForExistence(timeout: 4))
        app.buttons["1. Bunches Per Vine Count"].tap()
        XCTAssertTrue(app.navigationBars["Bunch Count Trip"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["yield.quadrant.count"].exists)
    }
    @MainActor func testQuadrantNormalControlsNormalizeThenResumeRawValuesAfterRelaunch() {
        let app = launch(admin: true); startQuadrant(app)
        let count = app.textFields["yield.quadrant.count"], length = app.textFields["yield.quadrant.length"]
        XCTAssertEqual(length.value as? String, "60")
        enter("12", field: count, app: app)
        XCTAssertTrue(app.staticTexts["Estimated: 20.0 bunches/vine"].waitForExistence(timeout: 3), "60 cm preview missing: \(app.debugDescription)")
        app.buttons["Record & Next"].tap()
        XCTAssertTrue(app.staticTexts["Sample 2 of 2"].waitForExistence(timeout: 4), "Did not advance after durable save: \(app.debugDescription)")
        enter("12", field: count, app: app); enter("50", field: length, app: app)
        XCTAssertTrue(app.staticTexts["Estimated: 24.0 bunches/vine"].waitForExistence(timeout: 3), "50 cm preview missing: \(app.debugDescription)")
        app.buttons["Record & Next"].tap()
        XCTAssertTrue(app.buttons["Finish Sampling"].waitForExistence(timeout: 4), "Second measurement not recorded: \(app.debugDescription)")
        app.buttons["All samples"].tap()
        XCTAssertTrue(app.staticTexts["20.0"].waitForExistence(timeout: 4), "First normalized sample missing: \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["24.0"].exists, "Second normalized sample missing: \(app.debugDescription)")
        app.buttons["Done"].tap()
        app.terminate()
        let resumed = launch(admin: true, reset: false)
        let resume = resumed.buttons["yield.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "Persisted draft not offered: \(resumed.debugDescription)")
        resume.tap()
        XCTAssertTrue(resumed.navigationBars["Quadrant Count"].waitForExistence(timeout: 5), "Persisted draft lost counting method: \(resumed.debugDescription)")
        let sampling = resumed.buttons["Continue Sampling"]; reveal(sampling, in: resumed); sampling.tap()
        XCTAssertTrue(resumed.textFields["yield.quadrant.count"].waitForExistence(timeout: 6), "Relaunch resume missing raw field: \(resumed.debugDescription)")
        XCTAssertEqual(resumed.textFields["yield.quadrant.count"].value as? String, "12")
        XCTAssertEqual(resumed.textFields["yield.quadrant.length"].value as? String, "60")
    }
    @MainActor func testMissingSpacingBlocksRecordingWithoutAssumedDefault() {
        let app = launch(admin: true, extra: ["--yield-missing-spacing"]); startQuadrant(app)
        enter("12", field: app.textFields["yield.quadrant.count"], app: app)
        XCTAssertTrue(app.staticTexts["Set spacing in Blocks"].exists)
        XCTAssertFalse(app.buttons["Record & Next"].isEnabled)
    }
    @MainActor func testFailedSaveKeepsRawInputAndDoesNotAdvance() {
        let app = launch(admin: true, extra: ["--yield-fail-saves"]); startQuadrant(app)
        enter("12", field: app.textFields["yield.quadrant.count"], app: app)
        app.buttons["Record & Next"].tap()
        XCTAssertTrue(app.alerts["Trip not saved"].waitForExistence(timeout: 4)); app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.staticTexts["Sample 1 of 2"].exists)
        XCTAssertEqual(app.textFields["yield.quadrant.count"].value as? String, "12")
        XCTAssertEqual(app.textFields["yield.quadrant.length"].value as? String, "60")
    }
}
