import XCTest

final class SprayLifecycleAcceptanceUITests: XCTestCase {
    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication, down: Bool = false) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "Required real UI control missing: \(element)")
        let viewport = CGRect(x: app.frame.minX, y: app.frame.minY + 125, width: app.frame.width, height: app.frame.height - 155)
        func visible() -> Bool {
            let frame = element.frame
            return frame.height > 0 && viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        for _ in 0..<18 where !visible() {
            if down { app.scrollViews.firstMatch.swipeDown() } else { app.scrollViews.firstMatch.swipeUp() }
        }
        XCTAssertTrue(visible(), "Required real UI control outside viewport: \(element); \(app.debugDescription)")
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor private func replaceTwice(_ field: XCUIElement, first: String, final: String, app: XCUIApplication) {
        reveal(field, app: app)
        field.tap(); field.typeText(first)
        XCTAssertEqual(field.value as? String, first, "First edit must replace the existing amount")
        app.buttons["keyboard.dismiss"].tap()
        field.tap(); field.typeText(final)
        XCTAssertEqual(field.value as? String, final, "Refocusing must select the existing amount, not concatenate")
        app.buttons["keyboard.dismiss"].tap()
    }

    @MainActor private func probe(_ count: Int, app: XCUIApplication) {
        let button = app.buttons["lifecycle.history.\(count)"]
        XCTAssertTrue(button.waitForExistence(timeout: 8)); button.tap()
        let report = app.staticTexts["lifecycle.performance"]
        let finished = NSPredicate(format: "label CONTAINS %@ OR label BEGINSWITH %@", "disk route verified", "Probe FAILED")
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: finished, object: report)], timeout: 35) == .completed,
            "Probe did not complete: \(report.label)")
        XCTAssertTrue(report.label.hasPrefix("points=\(count)→"), "Unexpected probe result: \(report.label)")
        XCTAssertTrue(report.label.contains("disk route verified"), "Probe integrity failure: \(report.label)")
        let attachment = XCTAttachment(string: report.label); attachment.name = "Sized history \(count) native measurements"
        attachment.lifetime = .keepAlways; add(attachment)
        capture(app, "Active Trip history \(count) with real GPS saves")
    }

    @MainActor private func runLifecycle(twoRow: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--keyboard-validation", "--spray-regional-validation", "--spray-direct-start-validation",
            "--spray-lifecycle-validation", "--spray-lifecycle-run", UUID().uuidString, "--lifecycle-history-performance"]
        if twoRow { app.launchArguments.append("--lifecycle-two-row") }
        app.launch()
        let open = app.buttons["Open Spray Calculator"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "Harness open control missing"); XCTAssertTrue(open.isEnabled, "Harness not ready"); open.tap()
        let review = app.buttons["spray.reviewTankMix"]
        reveal(review, app: app); XCTAssertTrue(review.isEnabled, "Valid fixture review disabled"); review.tap()
        let start = app.buttons["spray.startTrip"]
        XCTAssertTrue(start.waitForExistence(timeout: 8), "Review Start missing"); XCTAssertFalse(start.isEnabled, "Missing actuals must block")
        let water = app.textFields["spray.actualWater"]
        replaceTwice(water, first: "45", final: "450", app: app)
        let chemical = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "spray.actualChemical.")).firstMatch
        replaceTwice(chemical, first: "2.12345", final: "1", app: app)
        XCTAssertFalse(start.isEnabled, "Actual amounts do not invent a tracking choice")
        let freeDrive = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Free Drive")).firstMatch
        reveal(freeDrive, app: app); freeDrive.tap()
        reveal(start, app: app); XCTAssertTrue(start.isEnabled, "Entered actuals and Free Drive must enable Start")
        capture(app, "Valid manual 800 L, 500 L tank review")
        start.tap()
        let active = app.staticTexts["lifecycle.active"]
        XCTAssertTrue(active.waitForExistence(timeout: 15), "Start must leave Review and render production ActiveTripView")
        expectation(for: NSPredicate(format: "label == %@", "Active Trip • Tank 1 • ended 0"), evaluatedWith: active)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(active.isHittable, "Active Trip must be foreground, not behind a failed Review sheet")
        XCTAssertFalse(app.buttons["spray.startTrip"].exists, "Successful start dismisses Review")
        capture(app, "Successful Start to production Active Trip")
        for count in [100, 2_000, 10_000, 60_000] { probe(count, app: app) }
        let pause = app.buttons["trip.pauseResume"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        let pauseStart = ProcessInfo.processInfo.systemUptime
        pause.tap()
        expectation(for: NSPredicate(format: "label == %@", "Resume Trip"), evaluatedWith: pause)
        waitForExpectations(timeout: 8)
        let pauseSeconds = ProcessInfo.processInfo.systemUptime - pauseStart
        let resumeStart = ProcessInfo.processInfo.systemUptime
        pause.tap()
        expectation(for: NSPredicate(format: "label == %@", "Pause Trip"), evaluatedWith: pause)
        waitForExpectations(timeout: 8)
        let timing = XCTAttachment(string: "XCTest tap-to-query roundtrip, includes automation overhead: pause=\(pauseSeconds)s resume=\(ProcessInfo.processInfo.systemUptime - resumeStart)s; not isolated touch-to-render latency")
        timing.lifetime = .keepAlways; add(timing)
        let endTank = app.buttons["End Tank"]
        XCTAssertTrue(endTank.waitForExistence(timeout: 5), "Active Tank 1 End Tank missing: \(app.debugDescription)"); endTank.tap()
        let confirmEndTank = app.sheets.buttons["End Tank"].firstMatch
        XCTAssertTrue(confirmEndTank.waitForExistence(timeout: 5), "Tank confirmation missing: \(app.debugDescription)"); confirmEndTank.tap()
        let startTank = app.buttons["Start Tank"]
        XCTAssertTrue(startTank.waitForExistence(timeout: 8), "Tank 1 did not finish: \(app.debugDescription)")
        XCTAssertEqual(active.label, "Active Trip • Tank 0 • ended 1")
        startTank.tap()
        let confirmSecond = app.buttons["Confirm & Start Tank 2"]
        XCTAssertTrue(confirmSecond.waitForExistence(timeout: 8), "Tank 2 actual confirmation missing: \(app.debugDescription)")
        replaceTwice(app.textFields["spray.tankActual.Actual water"], first: "123.45678", final: "300.12345", app: app)
        replaceTwice(app.textFields["spray.tankActual.Actual Isolated product"], first: "2.34567", final: "0.12345", app: app)
        XCTAssertTrue(confirmSecond.isEnabled, "Tank 2 actuals invalid"); confirmSecond.tap()
        let tank2 = NSPredicate(format: "label == %@", "Active Trip • Tank 2 • ended 1")
        expectation(for: tank2, evaluatedWith: active); waitForExpectations(timeout: 8)
        let append = app.buttons["lifecycle.history.append"]
        XCTAssertTrue(append.waitForExistence(timeout: 5)); append.tap()
        let report = app.staticTexts["lifecycle.performance"]
        expectation(for: NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "points=", "disk route verified"), evaluatedWith: report)
        waitForExpectations(timeout: 35)
        capture(app, "Tank 2 remains active with additional durable GPS points before End Trip")
        let endTrip = app.buttons["trip.end"]
        XCTAssertTrue(endTrip.waitForExistence(timeout: 5), "End Trip control missing: \(app.debugDescription)"); endTrip.tap()
        let confirmEndTrip = app.sheets.buttons["End Trip"].firstMatch
        XCTAssertTrue(confirmEndTrip.waitForExistence(timeout: 5), "End Trip confirmation missing: \(app.debugDescription)"); confirmEndTrip.tap()
        let ended = app.staticTexts["lifecycle.ended"]
        XCTAssertTrue(ended.waitForExistence(timeout: 10), "End Trip did not finish: \(app.debugDescription)")
        XCTAssertEqual(app.staticTexts["lifecycle.tanks"].label, "Tank sessions: 2; ended: 2")
        XCTAssertEqual(app.staticTexts["lifecycle.order"].label, "Tank 2 persisted before Trip end")
        XCTAssertEqual(app.staticTexts["lifecycle.actuals"].label, "Actual records: 2")
        XCTAssertEqual(app.staticTexts["lifecycle.actualWater2"].label, "Tank 2 water L: 300.12345")
        XCTAssertEqual(app.staticTexts["lifecycle.actualChemical2"].label, "Tank 2 chemical display: 0.12345")
        XCTAssertGreaterThanOrEqual(Int(app.staticTexts["lifecycle.routeCount"].label) ?? 0, 60_006)
        let spray = app.staticTexts["lifecycle.spray"]
        expectation(for: NSPredicate(format: "label == %@", "Linked Spray finalised"), evaluatedWith: spray)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.staticTexts["lifecycle.error"].exists)
        let id = app.staticTexts["lifecycle.tripID"].label
        capture(app, "Both tanks ended and exact linked Spray finalised against simulated server")
        app.terminate(); app.launch()
        XCTAssertTrue(ended.waitForExistence(timeout: 10), "Completion survives actual process restart")
        XCTAssertEqual(app.staticTexts["lifecycle.tripID"].label, id)
        XCTAssertEqual(app.staticTexts["lifecycle.tanks"].label, "Tank sessions: 2; ended: 2")
        XCTAssertEqual(app.staticTexts["lifecycle.actuals"].label, "Actual records: 2")
        XCTAssertEqual(app.staticTexts["lifecycle.actualWater2"].label, "Tank 2 water L: 300.12345")
        XCTAssertEqual(app.staticTexts["lifecycle.actualChemical2"].label, "Tank 2 chemical display: 0.12345")
        XCTAssertGreaterThanOrEqual(Int(app.staticTexts["lifecycle.routeCount"].label) ?? 0, 60_006)
        XCTAssertEqual(app.staticTexts["lifecycle.order"].label, "Tank 2 persisted before Trip end")
        XCTAssertEqual(spray.label, "Linked Spray finalised")
        XCTAssertFalse(active.exists, "Restart must not resurrect an active Trip")
        capture(app, "Restart preserves completed lifecycle")
    }

    @MainActor func testSingleRowManual800LTwoTankLifecycleAndRestart() { runLifecycle(twoRow: false) }
    @MainActor func testTwoRowManual800LTwoTankLifecycleAndRestart() { runLifecycle(twoRow: true) }
}
