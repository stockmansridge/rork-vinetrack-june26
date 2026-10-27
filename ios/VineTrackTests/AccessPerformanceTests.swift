import XCTest
@testable import VineTrack

final class AccessPerformanceTests: XCTestCase {
    @MainActor func testIsolatedEnforcementOperationCosts() throws {
        let result = try SyntheticAccessPerformanceFixture.capture()
        let attachment = XCTAttachment(string: result.report)
        attachment.name = "Isolated access operation costs"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThan(result.maximum, 16, result.report)
    }
}
