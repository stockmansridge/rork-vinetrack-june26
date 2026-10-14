import XCTest

final class SprayPresentationUITests: XCTestCase {
    @MainActor private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation", "--spray-presentation-validation"]
        app.launch()
        XCTAssertTrue(app.buttons["Select label rate"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor func testWarningDetailsCloseWithoutAcknowledgementOrDraftMutation() {
        let app = launchFixture()
        app.buttons["spray.concentrationWarning"].tap()
        XCTAssertTrue(app.navigationBars["Concentration / Label Warning"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Synthetic sulphur"].exists)
        XCTAssertTrue(app.staticTexts["Synthetic copper"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Concentration warning details — synthetic native fixture"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["spray.concentrationWarning"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["spray.fixture.selection"].label, "No rate selected")
        XCTAssertFalse(app.navigationBars["Concentration / Label Warning"].exists)
    }

    @MainActor func testRateSheetPreservesUnitsLongRestrictionsAndRequiresExplicitChoice() {
        let app = launchFixture()
        let draft = app.textFields["spray.fixture.draft"]
        draft.tap()
        draft.typeText("3")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Select label rate"].tap()
        XCTAssertTrue(app.navigationBars["Select label rate"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["200–600 g/100 L"].exists)
        XCTAssertTrue(app.staticTexts["150–200 g/100 L"].exists)
        XCTAssertTrue(app.staticTexts["Apply from budburst onwards. Preserve the complete registered-use conditions without truncation."].exists)
        XCTAssertTrue(app.staticTexts["Do not exceed the seasonal maximum."].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Numeric-first registered rates — synthetic native fixture"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Close"].tap()
        XCTAssertEqual(app.staticTexts["spray.fixture.selection"].label, "No rate selected")
        XCTAssertEqual(draft.value as? String, "1253")
        app.buttons["Select label rate"].tap()
        app.buttons["spray.labelRate.22222222-2222-4222-8222-222222222222"].tap()
        XCTAssertTrue(app.staticTexts["spray.fixture.selection"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["spray.fixture.selection"].label, "Explicit rate selected")
    }

    @MainActor func testPlanningTermsAndBothNativeDiagramsRemainAvailable() {
        let app = launchFixture()
        XCTAssertTrue(app.buttons["Single Row"].exists)
        XCTAssertTrue(app.buttons["Only Full Tanks"].exists)
        XCTAssertFalse(app.buttons["Standard Pass"].exists)
        XCTAssertFalse(app.buttons["Full Tank"].exists)
        app.buttons["Over-Row"].tap()
        XCTAssertTrue(app.otherElements["Over-row boom with four spray heads treating both sides of two rows"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Over-Row arrowheads and Only Full Tanks — synthetic native fixture"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Single Row"].tap()
        XCTAssertTrue(app.otherElements["Single Row sprayer, arrows pointing left and right toward adjacent vine-row faces"].exists)
    }
}
