import Foundation
import XCTest
@testable import VineTrack

/// Issue #47: acceptance state follows persistent, exact-operation evidence
/// rather than the SwiftUI view's transient @State.
final class ManualSprayReviewStatusTests: XCTestCase {
    func testUnsavedReviewDoesNotClaimCompletion() {
        XCTAssertEqual(ManualSprayReviewStatus.reviewOnly.label, "Review only — not yet saved")
        XCTAssertTrue(ManualSprayReviewStatus.reviewOnly.canOfferSave)
        XCTAssertFalse(ManualSprayReviewStatus.reviewOnly.label.contains("Completed"))
    }

    func testRetainedOriginalPreventsNewSaveAfterReopen() {
        // The UI reconstructs this from coordinator.operations each time.
        let reopened = ManualSprayReviewStatus.resolve(
            serverConfirmed: false, hasRetainedSave: true, hasSubmissionMarker: false
        )
        XCTAssertEqual(reopened, .locallySavedAwaitingServer)
        XCTAssertFalse(reopened.canOfferSave)
        XCTAssertFalse(reopened.label.contains("Completed"))
    }

    func testBackgroundQueueRemovalIsNotServerProof() {
        // A background ACK may remove the outbox before a view receives a
        // server-confirmed response. The marker survives view recreation.
        let reopened = ManualSprayReviewStatus.resolve(
            serverConfirmed: false, hasRetainedSave: false, hasSubmissionMarker: true
        )
        XCTAssertEqual(reopened, .verificationRequired)
        XCTAssertFalse(reopened.canOfferSave)
        XCTAssertFalse(reopened.label.contains("Completed"))
    }

    func testInFlightRequestNeverOffersSaveOrDismissal() {
        let active = ManualSprayReviewStatus.resolve(
            serverConfirmed: false, hasRetainedSave: false,
            hasSubmissionMarker: true, isSaving: true
        )
        XCTAssertEqual(active, .submitting)
        XCTAssertFalse(active.canOfferSave)
        XCTAssertEqual(active.label, "Saving original manual spray — do not close")
    }

    func testCompletedOnlyAfterExactCoordinatorResponse() {
        let completed = ManualSprayReviewStatus.resolve(
            serverConfirmed: true, hasRetainedSave: false, hasSubmissionMarker: true
        )
        XCTAssertEqual(completed, .serverConfirmed)
        XCTAssertFalse(completed.canOfferSave)
        XCTAssertEqual(completed.label, "Completed — server confirmed")
    }

    func testSubmissionMarkerPersistsAcrossViewRecreationAndSeparatesScopes() async {
        await MainActor.run {
            let suiteName = "vinetrack.issue47.tests.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                XCTFail("Failed to create isolated test defaults")
                return
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let owner = UUID(), otherOwner = UUID()
            let vineyard = UUID(), otherVineyard = UUID()
            let originalId = UUID(), alternateId = UUID()
            let first = ManualSpraySubmissionGuard(defaults: defaults)
            XCTAssertTrue(first.mark(ownerId: owner, vineyardId: vineyard, manualEntryId: originalId))
            // Reopen with a freshly constructed service, not the original
            // SwiftUI @State.
            let reopened = ManualSpraySubmissionGuard(defaults: defaults)
            XCTAssertEqual(reopened.submittedId(ownerId: owner, vineyardId: vineyard, manualEntryId: originalId), originalId)
            XCTAssertTrue(reopened.mark(ownerId: owner, vineyardId: vineyard, manualEntryId: alternateId))
            XCTAssertEqual(reopened.submittedId(ownerId: owner, vineyardId: vineyard, manualEntryId: alternateId), alternateId)
            XCTAssertNil(reopened.submittedId(ownerId: otherOwner, vineyardId: vineyard, manualEntryId: originalId))
            XCTAssertNil(reopened.submittedId(ownerId: owner, vineyardId: otherVineyard, manualEntryId: originalId))
            reopened.clearIfMatching(ownerId: owner, vineyardId: vineyard, manualEntryId: alternateId)
            XCTAssertEqual(reopened.submittedId(ownerId: owner, vineyardId: vineyard, manualEntryId: originalId), originalId)
            reopened.clearIfMatching(ownerId: owner, vineyardId: vineyard, manualEntryId: originalId)
            XCTAssertNil(reopened.submittedId(ownerId: owner, vineyardId: vineyard, manualEntryId: originalId))
        }
    }
}
