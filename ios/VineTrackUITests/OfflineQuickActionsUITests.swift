import XCTest

final class OfflineQuickActionsUITests: XCTestCase {
    @MainActor func testOfflineSwitchBackgroundTerminateAndLocalPins() {
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation", "--offline-quick-actions-validation", "--reset-offline-quick-actions"]
        app.launch()
        XCTAssertTrue(app.buttons["Repairs"].waitForExistence(timeout: 10))
        for _ in 0..<2 {
            app.buttons["Switch vineyard"].tap()
            XCTAssertTrue(app.buttons["Growth"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Add Pin"].exists)
        }
        app.buttons["Repairs"].tap()
        XCTAssertEqual(app.staticTexts["offline.pins"].label, "Pending pins: 1")
        app.buttons["Switch vineyard"].tap()
        XCTAssertTrue(app.buttons["Growth"].waitForExistence(timeout: 5))
        app.buttons["Growth"].tap()
        XCTAssertEqual(app.staticTexts["offline.pins"].label, "Pending pins: 1")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["Add Pin"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--keyboard-validation", "--offline-quick-actions-validation"]
        app.launch()
        XCTAssertTrue(app.buttons["Repairs"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["offline.vineyard"].label, "Vineyard A")
        XCTAssertEqual(app.staticTexts["offline.pins"].label, "Pending pins: 1")
        app.buttons["Switch vineyard"].tap()
        XCTAssertTrue(app.buttons["Growth"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["offline.vineyard"].label, "Vineyard B")
        XCTAssertEqual(app.staticTexts["offline.pins"].label, "Pending pins: 1")
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Offline fixture: vineyard B pending pin after app relaunch"
        capture.lifetime = .keepAlways
        add(capture)
    }
}
