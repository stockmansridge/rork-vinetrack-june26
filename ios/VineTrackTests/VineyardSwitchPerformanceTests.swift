import Foundation
import XCTest
@testable import VineTrack

final class VineyardSwitchPerformanceTests: XCTestCase {
    /// Same substantial, isolated fixture used by the debug evidence screen.
    @MainActor func testSyntheticRepeatedSwitchStages() async throws {
        let report = try await SyntheticSwitchPerformanceFixture.capture()
        XCTAssertTrue(report.contains("Switch 4 total"))
        let attachment = XCTAttachment(string: report)
        attachment.name = "Synthetic production switch stages"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
