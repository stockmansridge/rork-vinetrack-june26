import XCTest
@testable import VineTrack

/// Native regression: a fixed-code timeline entry may only appear in the
/// same authenticated account + selected-vineyard export.
final class SyncSupportSnapshotScopeTests: XCTestCase {
    func testAccountAndVineyardIsolation() async {
        await MainActor.run {
            SyncDiagnosticHistory.clear()
            defer { SyncDiagnosticHistory.clear() }
            let accountA = UUID()
            let accountB = UUID()
            let vineyardA = UUID()
            let vineyardB = UUID()

            SyncDiagnosticHistory.record(.sweepStart, ownerId: accountA, vineyardId: vineyardA)
            SyncDiagnosticHistory.record(.sweepFailure, ownerId: accountB, vineyardId: vineyardA)
            SyncDiagnosticHistory.record(.manualRequest, ownerId: accountA, vineyardId: vineyardB)
            SyncDiagnosticHistory.record(.queueChange, ownerId: nil, vineyardId: vineyardA)

            let matching = SyncDiagnosticHistory.snapshot(ownerId: accountA, vineyardId: vineyardA)
            XCTAssertEqual(matching.count, 1)
            XCTAssertEqual(matching.first?.code, "sweep_start")
            XCTAssertEqual(SyncDiagnosticHistory.snapshot(ownerId: accountB, vineyardId: vineyardA).count, 1)
            XCTAssertEqual(SyncDiagnosticHistory.snapshot(ownerId: accountA, vineyardId: vineyardB).count, 1)
            XCTAssertTrue(SyncDiagnosticHistory.snapshot(ownerId: accountB, vineyardId: vineyardB).isEmpty)
        }
    }

    func testClearingRemovesStoredHistory() async {
        await MainActor.run {
            SyncDiagnosticHistory.clear()
            let owner = UUID(), vineyard = UUID()
            SyncDiagnosticHistory.record(.sweepFinish, ownerId: owner, vineyardId: vineyard)
            XCTAssertEqual(SyncDiagnosticHistory.snapshot(ownerId: owner, vineyardId: vineyard).count, 1)
            SyncDiagnosticHistory.clear()
            XCTAssertTrue(SyncDiagnosticHistory.snapshot(ownerId: owner, vineyardId: vineyard).isEmpty)
        }
    }
}
