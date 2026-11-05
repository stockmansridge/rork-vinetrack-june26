import XCTest

final class GPSPersistenceUITests: XCTestCase {
    @MainActor func testPauseResumeDuringPointByPointRecordingAndOfflineSync() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation", "--spray-lifecycle-validation", "--spray-lifecycle-run",
                               UUID().uuidString, "--gps-performance-validation"]
        app.launch()
        let record = app.buttons["gps.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 35))
        record.tap()
        let progress = app.staticTexts["gps.progress"]
        let pause = app.buttons["trip.pauseResume"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        let syncActive = NSPredicate(format: "label CONTAINS %@ AND NOT label CONTAINS %@", "inFlight=1", "injected=0;")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: syncActive, object: progress)], timeout: 12), .completed)
        let pauseStart = ProcessInfo.processInfo.systemUptime
        pause.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Resume Trip"), object: pause)], timeout: 5), .completed)
        let paused = ProcessInfo.processInfo.systemUptime - pauseStart
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: syncActive, object: progress)], timeout: 12), .completed)
        let resumeStart = ProcessInfo.processInfo.systemUptime
        pause.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pause Trip"), object: pause)], timeout: 5), .completed)
        let resumed = ProcessInfo.processInfo.systemUptime - resumeStart
        XCTAssertTrue(app.staticTexts["gps.complete"].waitForExistence(timeout: 135))
        let result = app.staticTexts["gps.result"].label
        XCTAssertTrue(result.hasPrefix("PASS"), result)
        XCTAssertTrue(result.contains("Pause service="), result)
        XCTAssertTrue(result.contains("Resume service="), result)
        XCTAssertTrue(result.contains("syncInFlight=1"), "At least one control must actually execute during the awaited sync transport, not merely near an earlier sync: \(result)")
        let timing = "XCTest tap-to-label roundtrips (includes automation, NOT isolated physical touch-to-render): Pause=\(paused)s Resume=\(resumed)s\n"
        let report = XCTAttachment(string: timing + app.staticTexts["gps.comparison"].label + "\n" + progress.label + "\n" + result)
        report.name = "GPS encoding, 120s recording, controls and RSS"; report.lifetime = .keepAlways; add(report)
        let image = XCTAttachment(screenshot: app.screenshot()); image.lifetime = .keepAlways; add(image)
    }
}
