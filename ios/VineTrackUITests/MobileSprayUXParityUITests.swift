import XCTest

final class MobileSprayUXParityUITests: XCTestCase {
    @MainActor func testHeaderEmptySpaceRespondsOnFirstTap() {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation", "--spray-calculator-keyboard-validation"]
        app.launch()
        let open = app.buttons["Open Spray Calculator"]
        XCTAssertTrue(open.waitForExistence(timeout: 8)); open.tap()
        let header = app.buttons["spray.header.application"]
        XCTAssertTrue(header.waitForExistence(timeout: 8))
        let name = app.textFields["e.g. Downy Mildew Spray #3"]
        for point in [CGVector(dx: 0.75, dy: 0.15), CGVector(dx: 0.08, dy: 0.5), CGVector(dx: 0.35, dy: 0.5), CGVector(dx: 0.95, dy: 0.5)] {
            header.coordinate(withNormalizedOffset: point).tap()
            XCTAssertTrue(name.waitForExistence(timeout: 3), "One tap anywhere in the header must open Application")
            header.tap()
            XCTAssertTrue(name.waitForNonExistence(timeout: 3))
        }
        header.tap()
        name.tap(); name.typeText("Parity fixture")
        app.buttons["keyboard.dismiss"].tap()
        XCTAssertTrue(name.exists, "Body interaction must not toggle the section")
    }

    @MainActor func testNotSetRoundTripContinuesThroughMixingWithoutStartingTrip() {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation", "--spray-calculator-keyboard-validation", "--spray-regional-validation", "--spray-direct-start-validation"]
        app.launch()
        let open = app.buttons["Open Spray Calculator"]
        XCTAssertTrue(open.waitForExistence(timeout: 8)); open.tap()
        let scroll = app.scrollViews.firstMatch
        let carrier = app.buttons["spray.header.carrier"]
        for _ in 0..<12 where !carrier.isHittable { scroll.swipeDown() }
        carrier.tap()
        let passes = app.segmentedControls["spray.passConfiguration"]
        XCTAssertTrue(passes.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<12 where !passes.isHittable { scroll.swipeUp() }
        for title in ["Not Set", "Single Row", "Over-Row", "Not Set"] {
            passes.buttons[title].tap()
            for stable in ["Not Set", "Single Row", "Over-Row"] { XCTAssertTrue(passes.buttons[stable].exists) }
        }
        let products = app.buttons["spray.continue.products"]
        for _ in 0..<16 where !products.isHittable { scroll.swipeUp() }
        XCTAssertTrue(products.isEnabled); products.tap()
        let review = app.buttons["Continue to Review →"]
        for _ in 0..<12 where !review.isHittable { scroll.swipeUp() }
        XCTAssertTrue(review.waitForExistence(timeout: 5)); review.tap()
        let mixing = app.buttons["spray.reviewTankMix"]
        for _ in 0..<14 where !mixing.isHittable { scroll.swipeUp() }
        XCTAssertTrue(mixing.isEnabled); mixing.tap()
        let start = app.buttons["spray.startTrip"]
        for _ in 0..<12 where !start.isHittable { scroll.swipeUp() }
        XCTAssertTrue(start.waitForExistence(timeout: 5)); XCTAssertTrue(start.isEnabled)
    }

    @MainActor func testCanopyConfirmationFocusesRateQuestionAndCustomEntry() {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation", "--spray-calculator-keyboard-validation", "--spray-regional-validation"]
        app.launch()
        let open = app.buttons["Open Spray Calculator"]
        XCTAssertTrue(open.waitForExistence(timeout: 8)); open.tap()
        let scroll = app.scrollViews.firstMatch
        app.buttons["By Area"].tap()
        let vsp = app.buttons["VSP"]
        for _ in 0..<12 where !vsp.isHittable { scroll.swipeUp() }
        vsp.tap()
        let confirm = app.buttons["Confirm Canopy — VSP · Medium · Low"]
        for _ in 0..<10 where !confirm.isHittable { scroll.swipeUp() }
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        let question = app.staticTexts["Spray at the recommended volume?"]
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        XCTAssertTrue(question.isHittable, "Confirmation must bring the next question into view")
        let custom = app.buttons["Set my own rate"]
        for _ in 0..<4 where !custom.isHittable { scroll.swipeUp() }
        custom.tap()
        XCTAssertTrue(app.textFields["spray.customRate"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["spray.header.carrier"].exists)
    }
}
