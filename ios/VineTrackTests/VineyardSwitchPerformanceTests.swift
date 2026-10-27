import Foundation
import XCTest
@testable import VineTrack

final class VineyardSwitchPerformanceTests: XCTestCase {
    @MainActor func testPairedWarmAlternatingSwitchesDoNotSystematicallyRegress() async throws {
        let baseline = try await SyntheticSwitchPerformanceFixture.capture(prepared: false)
        let before = SyntheticSwitchPerformanceFixture.warmCommits.sorted()
        let prepared = try await SyntheticSwitchPerformanceFixture.capture()
        let after = SyntheticSwitchPerformanceFixture.warmCommits.sorted()
        XCTAssertEqual(before.count, 24)
        XCTAssertEqual(after.count, 24)
        // A two-millisecond noise allowance on the median, not an incentive to
        // optimise the historical 0.62ms difference or discard outliers.
        XCTAssertLessThanOrEqual(after[after.count / 2], before[before.count / 2] + 2,
                                 "Paired warm median regressed\nCONTROL\n\(baseline)\nPREPARED\n\(prepared)")
        let attachment = XCTAttachment(string: "CONTROL\n\(baseline)\nPREPARED\n\(prepared)")
        attachment.name = "Paired 24 warm switch distributions"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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
