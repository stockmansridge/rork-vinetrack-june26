import XCTest

final class TripSwipeDeletionUITests: XCTestCase {
    @MainActor func testSwipeCancelConfirmAndActiveRefusalKeepExactRows() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation", "--trip-delete-validation"]
        app.launch()
        let state = app.staticTexts["trip.delete.fixture.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 10), "Isolated shipping list must launch")
        XCTAssertEqual(state.label, "Rows: 3 · Disk: 3 · Deletes: 0")
        let row = app.descendants(matching: .any)["trip.history.35000000-0000-4000-8000-000000000001"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Completed fixture row must be accessible")
        row.swipeLeft()
        let swipeDelete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(swipeDelete.waitForExistence(timeout: 3), "Completed row must offer swipe Delete"); swipeDelete.tap()
        let alert = app.alerts["Delete Trip"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3), "Swipe must present confirmation before mutation"); alert.buttons["Cancel"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3), "Cancel must dismiss confirmation")
        XCTAssertTrue(row.exists)
        XCTAssertEqual(state.label, "Rows: 3 · Disk: 3 · Deletes: 0")
        row.swipeLeft()
        XCTAssertTrue(swipeDelete.waitForExistence(timeout: 3), "Completed row must offer swipe Delete"); swipeDelete.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 3), "Second swipe must confirm deletion"); alert.buttons["Delete"].tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "Confirmed row must be removed")
        XCTAssertEqual(state.label, "Rows: 2 · Disk: 2 · Deletes: 1")
        XCTAssertTrue(app.descendants(matching: .any)["trip.history.35000000-0000-4000-8000-000000000002"].firstMatch.exists, "Other completed row must survive")
        let active = app.descendants(matching: .any)["trip.history.35000000-0000-4000-8000-000000000003"].firstMatch
        XCTAssertTrue(active.exists, "Active fixture row must survive"); active.swipeLeft()
        XCTAssertFalse(app.buttons["Delete"].exists, "Active Trip must have no deletion action")
        XCTAssertFalse(alert.exists)
        XCTAssertEqual(state.label, "Rows: 2 · Disk: 2 · Deletes: 1")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
