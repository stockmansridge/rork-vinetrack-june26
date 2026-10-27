import XCTest
@testable import VineTrack

final class HomeSyncPerformanceTests: XCTestCase {
    @MainActor func testMountedHomeDuringProductionSyncApplication() async throws {
        let result = try await SyntheticHomePerformanceFixture.capture()
        let attachment = XCTAttachment(string: result.report)
        attachment.name = "Mounted Home sync application numeric evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(result.summaryCount, 0, "Actual Home summary must render")
        XCTAssertLessThan(result.longestMainStage, 16, result.report)
    }
}
