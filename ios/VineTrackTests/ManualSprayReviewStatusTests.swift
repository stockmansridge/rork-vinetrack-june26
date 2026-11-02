import XCTest
@testable import VineTrack

/// Issue #47: an unsaved review or a retained local queue is not proof that
/// the manual spray was received as a completed regulatory record.
final class ManualSprayReviewStatusTests: XCTestCase {
    func testUnsavedReviewDoesNotClaimCompletion() {
        XCTAssertEqual(ManualSprayReviewStatus.reviewOnly.label, "Review only — not yet saved")
        XCTAssertFalse(ManualSprayReviewStatus.reviewOnly.label.contains("Completed"))
    }

    func testLocallyQueuedDoesNotClaimServerReceipt() {
        XCTAssertEqual(ManualSprayReviewStatus.locallySavedAwaitingServer.label,
                       "Saved on device — awaiting server confirmation")
        XCTAssertFalse(ManualSprayReviewStatus.locallySavedAwaitingServer.label.contains("Completed"))
    }

    func testCompletedRequiresVerifiedServerReply() {
        XCTAssertEqual(ManualSprayReviewStatus.serverConfirmed.label,
                       "Completed — server confirmed")
    }
}
