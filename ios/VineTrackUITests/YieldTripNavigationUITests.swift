import XCTest

final class YieldTripNavigationUITests: XCTestCase {
    @MainActor private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation", "--yield-trip-validation"] + (reset ? ["--reset-yield-trip"] : [])
        app.launch()
        XCTAssertTrue(app.navigationBars["Bunch Count Trips"].waitForExistence(timeout: 10))
        return app
    }
    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.85))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.2))
            start.press(forDuration: 0.01, thenDragTo: end)
        }
        XCTAssertTrue(element.exists && element.isHittable, "Could not scroll to \(element.identifier)")
    }
    @MainActor func testResumeAndBackReturnsToTripsNotYieldRoot() {
        let app = launch(reset: true)
        app.buttons["yield.resume"].tap()
        XCTAssertTrue(app.navigationBars["Bunch Count Trip"].waitForExistence(timeout: 5))
        app.buttons["yield.backToTrips"].tap()
        XCTAssertTrue(app.navigationBars["Bunch Count Trips"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["yield.resume"].exists)
    }
    @MainActor func testCompletionRefreshReopenAndProcessRelaunchKeepCompletedTrip() {
        let app = launch(reset: true)
        app.buttons["yield.resume"].tap()
        let save = app.buttons["yield.saveTrip"]; reveal(save, app: app); save.tap()
        let confirm = app.buttons["Save Trip"]; XCTAssertTrue(confirm.waitForExistence(timeout: 4)); confirm.tap()
        XCTAssertTrue(app.navigationBars["Bunch Count Trips"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["yield.resume"].waitForNonExistence(timeout: 5), "Saved completed trip must no longer appear as a draft")
        let id = "yield.completed.99999999-9999-4999-8999-999999999999"
        let completed = app.buttons[id]; reveal(completed, app: app); completed.tap()
        XCTAssertTrue(app.staticTexts["Bunch Count Trip Completed"].waitForExistence(timeout: 5), "Opening the saved trip must show completed banner")
        XCTAssertTrue(app.buttons["yield.saveTrip"].waitForNonExistence(timeout: 5), "Reopened completed trip must not show save action")
        app.buttons["yield.backToTrips"].tap()
        XCTAssertTrue(app.navigationBars["Bunch Count Trips"].waitForExistence(timeout: 5))
        app.terminate()
        let relaunched = launch(reset: false)
        XCTAssertTrue(relaunched.buttons["yield.resume"].waitForNonExistence(timeout: 5), "Persisted completion must not reload as a draft")
        let persisted = relaunched.buttons[id]; reveal(persisted, app: relaunched); persisted.tap()
        XCTAssertTrue(relaunched.staticTexts["Bunch Count Trip Completed"].waitForExistence(timeout: 5), "Completed banner must survive process relaunch")
    }
}
