import XCTest

final class MobileSprayUXParityUITests: XCTestCase {
    @MainActor func testPhase2RecommendedToReview() { runGuidedJourney() }
    @MainActor func testPhase2CustomToReview() { runGuidedJourney(custom: true) }
    @MainActor func testPhase2BandedToReview() { runGuidedJourney(operation: "Banded Spray") }
    @MainActor func testPhase2SpreaderToReview() { runGuidedJourney(operation: "Spreader") }
    @MainActor func testPhase2EditBlocks() { runGuidedJourney(editBlocks: true) }
    @MainActor func testPhase2ProgramPrefill() { runGuidedJourney(prefilled: true) }

    @MainActor private func reach(_ element: XCUIElement, in app: XCUIApplication, down: Bool = false) {
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<16 where !element.isHittable {
            if down { scroll.swipeDown() } else { scroll.swipeUp() }
        }
        XCTAssertTrue(element.isHittable, element.description)
    }

    @MainActor private func advance(_ next: String, in app: XCUIApplication) {
        let action = app.buttons["spray.continue.\(next)"]
        reach(action, in: app)
        XCTAssertTrue(action.isEnabled, app.staticTexts["spray.regional.prerequisites"].label)
        action.tap()
        let header = app.buttons["spray.header.\(next)"]
        XCTAssertTrue(header.waitForExistence(timeout: 5), "Missing next heading: \(next)")
        XCTAssertTrue(header.isHittable, "Continue must expose the next heading without a manual scroll")
        XCTAssertTrue(app.scrollViews.firstMatch.frame.contains(header.frame), "The whole next heading must be visible")
    }

    @MainActor private func chooseBlocks(_ all: Bool, in app: XCUIApplication) {
        let selector = app.buttons["spray.blocks.selector"]
        reach(selector, in: app); selector.tap()
        let choice = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", all ? "Select All" : "Deselect All")).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "Block picker must offer the deliberate selection action"); choice.tap()
        app.buttons["Done"].tap()
    }

    @MainActor private func runGuidedJourney(operation: String = "Foliar Spray", custom: Bool = false, editBlocks: Bool = false, prefilled: Bool = false) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation", "--spray-calculator-keyboard-validation", "--spray-regional-validation", "--spray-phase2-validation"]
        if prefilled { app.launchArguments.append("--spray-phase2-prefill") }
        app.launch()
        let open = app.buttons["Open Spray Calculator"]
        XCTAssertTrue(open.waitForExistence(timeout: 8), "Fixture must show Open Spray Calculator"); open.tap()
        let name = app.textFields["e.g. Downy Mildew Spray #3"]
        if prefilled {
            let header = app.buttons["spray.header.application"]
            XCTAssertTrue(header.waitForExistence(timeout: 8))
            if !name.exists { reach(header, in: app, down: true); header.tap() }
            XCTAssertEqual(name.value as? String, "Synthetic program")
            XCTAssertFalse(app.buttons["spray.header.blocks"].isEnabled)
            XCTAssertFalse(app.buttons["spray.continue.blocks"].isEnabled)
            app.buttons["spray.operation"].tap()
            app.buttons[operation].tap()
            XCTAssertTrue(name.exists, "Program Application stays open until Continue")
        } else {
            XCTAssertTrue(name.waitForExistence(timeout: 8), "New Application must be expanded")
            XCTAssertFalse(app.buttons["spray.header.blocks"].isEnabled)
            XCTAssertFalse(app.buttons["spray.continue.blocks"].isEnabled)
            app.buttons["spray.operation"].tap()
            app.buttons[operation].tap()
            XCTAssertTrue(name.exists, "Choosing an answer must keep Application open")
        }
        advance("blocks", in: app)
        if !prefilled {
            XCTAssertFalse(app.buttons["spray.continue.target"].isEnabled)
            chooseBlocks(true, in: app)
        }
        advance("target", in: app)
        if !prefilled { let target = app.buttons["Powdery Mildew"]; reach(target, in: app); target.tap() }
        if operation == "Banded Spray" {
            let target = app.buttons["Undervine"]; reach(target, in: app); target.tap()
            let width = app.textFields["spray.bandWidth"]
            reach(width, in: app); width.tap(); width.typeText("0.8")
            app.buttons["keyboard.dismiss"].tap()
        } else if operation == "Foliar Spray" {
            let target = app.buttons["Full Canopy"]; reach(target, in: app); target.tap()
        }
        advance("growthStage", in: app)
        XCTAssertTrue(app.buttons["spray.header.target"].label.contains("Powdery"), "Supplied or chosen target must remain resolved")
        if !prefilled {
            let selector = app.buttons["spray.growth.selector"]
            reach(selector, in: app); selector.tap()
            let notSet = app.buttons["Not Set"].firstMatch
            reach(notSet, in: app); notSet.tap()
            reach(selector, in: app, down: true); selector.tap()
        }
        advance("equipment", in: app)
        if editBlocks {
            let blocks = app.buttons["spray.header.blocks"]
            reach(blocks, in: app, down: true); blocks.tap()
            chooseBlocks(false, in: app)
            XCTAssertFalse(app.buttons["spray.continue.target"].isEnabled)
            XCTAssertFalse(app.buttons["spray.header.equipment"].isEnabled)
            chooseBlocks(true, in: app)
            advance("target", in: app)
            advance("growthStage", in: app)
            XCTAssertTrue(app.buttons["spray.header.target"].label.contains("Powdery"))
            advance("equipment", in: app)
        }
        let equipment = app.buttons["spray.equipment.selector"]
        reach(equipment, in: app); equipment.tap()
        let unit = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Synthetic 1000 L unit")).allElementsBoundByIndex.last!
        reach(unit, in: app); unit.tap()
        reach(equipment, in: app, down: true); equipment.tap()
        let confirmEquipment = app.buttons["Confirm Equipment"]
        reach(confirmEquipment, in: app); confirmEquipment.tap()
        advance("carrier", in: app)
        if operation == "Foliar Spray" {
            let vsp = app.buttons["VSP"]; reach(vsp, in: app); vsp.tap()
            let confirm = app.buttons["spray.confirm.canopy"]
            reach(confirm, in: app); confirm.tap()
            let choice = app.buttons[custom ? "Set my own rate" : "Use recommended rate"]
            reach(choice, in: app); choice.tap()
            if custom {
                let rate = app.textFields["spray.customRate"]
                reach(rate, in: app); rate.tap(); rate.typeText("600")
                app.buttons["keyboard.dismiss"].tap()
            }
        } else if operation == "Banded Spray" {
            XCTAssertFalse(app.buttons["VSP"].exists)
            let rate = app.textFields["spray.groundRate"]
            reach(rate, in: app); rate.tap(); rate.typeText("200")
            app.buttons["keyboard.dismiss"].tap()
        } else {
            let manual = app.segmentedControls.buttons["Manual"]
            reach(manual, in: app); manual.tap()
            let water = app.textFields["spray.manualWater"]
            reach(water, in: app); water.tap(); water.typeText("400")
            app.buttons["keyboard.dismiss"].tap()
            XCTAssertFalse(app.buttons["spray.confirm.canopy"].exists, "Spreader manual water must not require canopy confirmation")
        }
        advance("products", in: app)
        let add = app.buttons["Add Chemical"]; reach(add, in: app); add.tap()
        let product = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Synthetic product")).firstMatch
        XCTAssertTrue(product.waitForExistence(timeout: 5), "Synthetic product must be offered in the production picker"); product.tap()
        if operation == "Banded Spray" {
            let basis = app.buttons["Treated Band Area"]; reach(basis, in: app); basis.tap()
        }
        advance("review", in: app)
        XCTAssertTrue(app.buttons["spray.reviewTankMix"].exists, "Keep the existing Review handoff")
    }

    @MainActor func testNewOneOffRecommendedCarrierUnlocksProducts() {
        runNewOneOffCarrier(custom: false)
    }

    @MainActor func testNewOneOffCustomCarrierUnlocksProducts() {
        runNewOneOffCarrier(custom: true)
    }

    @MainActor private func runNewOneOffCarrier(custom: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation", "--spray-calculator-keyboard-validation", "--spray-regional-validation", "--spray-phase1-validation"]
        app.launch()
        let open = app.buttons["Open Spray Calculator"]
        XCTAssertTrue(open.waitForExistence(timeout: 8), "Fixture must show Open Spray Calculator"); open.tap()
        let scroll = app.scrollViews.firstMatch
        let name = app.textFields["e.g. Downy Mildew Spray #3"]
        XCTAssertTrue(name.waitForExistence(timeout: 8), "New Application must start expanded")
        XCTAssertFalse(app.buttons["spray.header.blocks"].isEnabled)
        XCTAssertFalse(app.buttons["spray.continue.blocks"].isEnabled)
        let live = app.staticTexts["spray.phase1.live"]
        XCTAssertTrue(live.label.contains("application=false"))
        app.buttons["spray.operation"].tap()
        app.buttons["Foliar Spray"].tap() // Deliberate selection of the already displayed default.
        let blocks = app.buttons["spray.continue.blocks"]
        XCTAssertTrue(blocks.waitForExistence(timeout: 3))
        XCTAssertTrue(name.exists, "Selection must not auto-collapse")
        blocks.tap()
        XCTAssertFalse(name.exists)
        let carrier = app.buttons["spray.header.carrier"]
        for _ in 0..<12 where !carrier.isHittable { scroll.swipeUp() }
        XCTAssertTrue(carrier.isEnabled); carrier.tap()
        let vsp = app.buttons["VSP"]
        for _ in 0..<12 where !vsp.isHittable { scroll.swipeUp() }
        vsp.tap()
        let confirm = app.buttons["spray.confirm.canopy"]
        for _ in 0..<12 where !confirm.isHittable { scroll.swipeUp() }
        XCTAssertEqual(app.buttons.matching(identifier: "spray.confirm.canopy").count, 1)
        XCTAssertFalse(app.otherElements["spray.carrier.blocker"].exists, "No duplicate warning below the confirmation action; the header summary may still name the outstanding step")
        XCTAssertTrue(live.label.contains("canopy=false carrier=Confirm canopy"))
        confirm.tap()
        let question = app.staticTexts["Spray at the recommended volume?"]
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        XCTAssertTrue(live.label.contains("canopy=true carrier=Choose your spray volume products=false"), live.label)
        XCTAssertTrue(app.staticTexts["RECOMMENDED SPRAY VOLUME — CF 1.00"].exists, "Live confirmation must render the engine recommendation")
        let choice = app.buttons[custom ? "Set my own rate" : "Use recommended rate"]
        for _ in 0..<6 where !choice.isHittable { scroll.swipeUp() }
        choice.tap()
        if custom {
            let rate = app.textFields["spray.customRate"]
            for _ in 0..<8 where !rate.isHittable { scroll.swipeUp() }
            XCTAssertTrue(live.label.contains("carrier=Enter sprayer output products=false"), live.label)
            rate.tap(); rate.typeText("600")
            app.buttons["keyboard.dismiss"].tap()
        }
        XCTAssertTrue(live.label.contains("canopy=true carrier=none products=true"), live.label)
        let products = app.buttons["spray.continue.products"]
        for _ in 0..<16 where !products.isHittable { scroll.swipeUp() }
        XCTAssertTrue(products.isEnabled); products.tap()
        XCTAssertTrue(app.buttons["Add Chemical"].waitForExistence(timeout: 5), "Continue must open the real Products body")
    }

    @MainActor func testHeaderEmptySpaceRespondsOnFirstTap() {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation", "--spray-calculator-keyboard-validation"]
        app.launch()
        let open = app.buttons["Open Spray Calculator"]
        XCTAssertTrue(open.waitForExistence(timeout: 8), "Fixture must show Open Spray Calculator"); open.tap()
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
        XCTAssertTrue(open.waitForExistence(timeout: 8), "Fixture must show Open Spray Calculator"); open.tap()
        let scroll = app.scrollViews.firstMatch
        let carrier = app.buttons["spray.header.carrier"]
        for _ in 0..<12 where !carrier.isHittable { scroll.swipeDown() }
        carrier.tap()
        let passes = app.segmentedControls["spray.passConfiguration"]
        XCTAssertTrue(passes.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<12 where !passes.isHittable { scroll.swipeUp() }
        for title in ["Not Set", "Single Row", "2 Row", "Not Set"] {
            passes.buttons[title].tap()
            for stable in ["Not Set", "Single Row", "2 Row"] { XCTAssertTrue(passes.buttons[stable].exists) }
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
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(start.isEnabled, "Actual rate confirmation is required, not warning acknowledgement")
        let rateConfirmation = app.switches["spray.confirmActualRates"]
        for _ in 0..<12 where !rateConfirmation.isHittable { app.scrollViews.firstMatch.swipeDown() }
        XCTAssertTrue(rateConfirmation.waitForExistence(timeout: 5))
        rateConfirmation.tap()
        for _ in 0..<12 where !start.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(start.isEnabled, "Confirmed valid mix starts without acknowledging advisory warnings")
    }

    @MainActor func testCanopyConfirmationFocusesRateQuestionAndCustomEntry() {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation", "--spray-calculator-keyboard-validation", "--spray-regional-validation"]
        app.launch()
        let open = app.buttons["Open Spray Calculator"]
        XCTAssertTrue(open.waitForExistence(timeout: 8), "Fixture must show Open Spray Calculator"); open.tap()
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
