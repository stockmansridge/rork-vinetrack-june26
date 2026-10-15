import XCTest

final class LegacySprayRecoveryUITests: XCTestCase {
    @MainActor func testExactOriginalPairRecoversAfterRealAppTerminationAtEachLocalBoundary() {
        let app = XCUIApplication()
        for stage in ["prepared", "recipe", "trip", "complete"] {
            let id = UUID().uuidString
            app.launchArguments = ["--keyboard-validation", "--legacy-recovery-case", id, stage]
            app.launch()
            let outcome = app.staticTexts["legacy.recovery.result"]
            XCTAssertTrue(outcome.waitForExistence(timeout: 10))
            XCTAssertEqual(outcome.label, "Original intent retained at \(stage)")
            app.terminate()
            app.launchArguments = ["--keyboard-validation", "--legacy-recovery-case", id, "recover"]
            app.launch()
            XCTAssertTrue(outcome.waitForExistence(timeout: 10))
            XCTAssertEqual(outcome.label, "Recovered exact original pair; no active tracking")
            app.terminate()
            app.launchArguments = ["--keyboard-validation", "--legacy-recovery-case", id, "cleanup"]
            app.launch()
            XCTAssertTrue(outcome.waitForExistence(timeout: 10))
            XCTAssertEqual(outcome.label, "Cleaned isolated fixture")
            app.terminate()
        }
    }
}
