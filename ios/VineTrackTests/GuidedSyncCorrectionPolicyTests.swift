import Foundation
import XCTest
@testable import VineTrack

/// Settings -> Sync Diagnostics -> Review & repair sync issues.
/// Pure policy tests must not touch persisted queues or production data.
final class GuidedSyncCorrectionPolicyTests: XCTestCase {
    private func item(
        kind: GuidedSyncRepairIssue.Kind, scoped: Bool = true,
        actual: Bool = false
    ) -> GuidedSyncRepairIssue {
        let id = UUID()
        return GuidedSyncRepairIssue(
            id: kind.rawValue + ":" + id.uuidString,
            recordId: id,
            relatedTripId: scoped ? id : nil,
            kind: kind,
            title: "Test",
            detail: "Retained original",
            verifiedCurrentScope: scoped,
            originalActualAvailable: actual)
    }

    func testUnknownOwnershipAllowsOnlyPrivateReview() {
        let kinds: [GuidedSyncRepairIssue.Kind] = [.tripUpload, .tripDeletion, .tankActual, .sprayRecord, .protectedQueue]
        for kind in kinds {
            let record = item(kind: kind, scoped: false, actual: true)
            let states: [GuidedSyncRecordState] = [.notChecked, .active, .ended, .deleted, .notVisible]
            for state in states {
                let expected: [GuidedSyncCorrection] =
                    kind == .protectedQueue && state == .deleted
                    ? [.reviewLegacyDeleted, .privateReview] : [.privateReview]
                XCTAssertEqual(GuidedSyncCorrectionPolicy.available(for: record, server: state), expected)
            }
        }
    }

    func testNoMutationBeforeReadbackOrWhenRowNotVisible() {
        let original = item(kind: .tripUpload, actual: true)
        XCTAssertEqual(GuidedSyncCorrectionPolicy.available(for: original, server: .notChecked), [.privateReview])
        XCTAssertEqual(GuidedSyncCorrectionPolicy.available(for: original, server: .notVisible), [.privateReview])
    }

    func testDeletedTripNeverOffersRestartTankRepairOrFinalisation() {
        let original = item(kind: .tripUpload, actual: true)
        XCTAssertEqual(GuidedSyncCorrectionPolicy.available(for: original, server: .deleted),
                       [.reviewLegacyDeleted, .privateReview])
        XCTAssertFalse(GuidedSyncCorrectionPolicy.available(for: original, server: .deleted)
            .contains(.recoverRecordedTank))

        let cancellation = item(kind: .tripDeletion)
        XCTAssertEqual(GuidedSyncCorrectionPolicy.available(for: cancellation, server: .deleted),
                       [.verifyCancellation, .reviewLegacyDeleted, .privateReview])
        XCTAssertEqual(GuidedSyncCorrectionPolicy.available(for: cancellation, server: .active),
                       [.verifyCancellation, .privateReview])
        XCTAssertEqual(GuidedSyncCorrectionPolicy.available(for: cancellation, server: .ended), [.privateReview])
    }

    func testRecordedTankRepairOnlyOfferedForActiveOriginalWithActualEvidence() {
        let withProof = item(kind: .tripUpload, actual: true)
        let withoutProof = item(kind: .tripUpload, actual: false)
        XCTAssertTrue(GuidedSyncCorrectionPolicy.available(for: withProof, server: .active)
            .contains(.recoverRecordedTank))
        XCTAssertFalse(GuidedSyncCorrectionPolicy.available(for: withoutProof, server: .active)
            .contains(.recoverRecordedTank))
        XCTAssertFalse(GuidedSyncCorrectionPolicy.available(for: withProof, server: .ended)
            .contains(.recoverRecordedTank))
    }

    func testCompletedTripOnlyOffersReadbackReconciliationNotTankReconstruction() {
        let trip = item(kind: .tripUpload, actual: true)
        let options = GuidedSyncCorrectionPolicy.available(for: trip, server: .ended)
        XCTAssertTrue(options.contains(.verifyCompleted))
        XCTAssertFalse(options.contains(.recoverRecordedTank))
    }

    func testReviewedLegacyDeletedRequiresExactServerTombstoneAndOwnerConfirmationPath() {
        let original = item(kind: .protectedQueue, scoped: false)
        XCTAssertEqual(GuidedSyncCorrectionPolicy.available(for: original, server: .active),
                       [.privateReview])
        XCTAssertEqual(GuidedSyncCorrectionPolicy.available(for: original, server: .notVisible),
                       [.privateReview])
        XCTAssertEqual(GuidedSyncCorrectionPolicy.available(for: original, server: .deleted),
                       [.reviewLegacyDeleted, .privateReview])
        XCTAssertFalse(GuidedSyncCorrectionPolicy.available(for: original, server: .deleted)
            .contains(.retryExisting))
        XCTAssertFalse(GuidedSyncCorrectionPolicy.available(for: original, server: .deleted)
            .contains(.recoverRecordedTank))
    }

    func testAcceptedActualAllowsAuditedCorrectionButPendingActualCannotAmend() {
        let actual = item(kind: .tankActual)
        XCTAssertFalse(GuidedSyncCorrectionPolicy.available(
            for: actual, server: .active, actualAccepted: false).contains(.amendActualUse))
        XCTAssertFalse(GuidedSyncCorrectionPolicy.available(
            for: actual, server: .active, actualAccepted: false).contains(.correctPendingActualUse))
        XCTAssertTrue(GuidedSyncCorrectionPolicy.available(
            for: actual, server: .active, actualPending: true).contains(.correctPendingActualUse))
        XCTAssertFalse(GuidedSyncCorrectionPolicy.available(
            for: actual, server: .deleted, actualPending: true).contains(.correctPendingActualUse))
        XCTAssertTrue(GuidedSyncCorrectionPolicy.available(
            for: actual, server: .active, actualAccepted: true).contains(.amendActualUse))
        XCTAssertFalse(GuidedSyncCorrectionPolicy.available(
            for: actual, server: .deleted, actualAccepted: true).contains(.amendActualUse))
    }

    func testSavedInitialMixAndTrackedCompletionCannotInventHistory() {
        let kinds: [GuidedSyncRepairIssue.Kind] = [.initialMixDraft, .trackedSprayCompletion]
        for kind in kinds {
            let row = item(kind: kind)
            XCTAssertEqual(GuidedSyncCorrectionPolicy.available(for: row, server: .active),
                           [.retryExisting, .privateReview])
            XCTAssertEqual(GuidedSyncCorrectionPolicy.available(for: row, server: .deleted),
                           [.privateReview])
        }
    }

    func testLegacyScopeRequiresExactSelectedVineyardAndOriginalId() {
        let original = UUID(), selected = UUID(), foreign = UUID()
        XCTAssertEqual(GuidedLegacyServerScope.classify(
            queuedID: original, selectedVineyard: selected, serverID: original,
            serverVineyard: selected, deletedAt: Date()), .selectedDeleted)
        XCTAssertEqual(GuidedLegacyServerScope.classify(
            queuedID: original, selectedVineyard: selected, serverID: original,
            serverVineyard: selected, deletedAt: nil), .selectedNotDeleted)
        XCTAssertEqual(GuidedLegacyServerScope.classify(
            queuedID: original, selectedVineyard: selected, serverID: original,
            serverVineyard: foreign, deletedAt: Date()), .unattributed)
        XCTAssertEqual(GuidedLegacyServerScope.classify(
            queuedID: original, selectedVineyard: selected, serverID: UUID(),
            serverVineyard: selected, deletedAt: Date()), .unattributed)
        XCTAssertEqual(GuidedLegacyServerScope.classify(
            queuedID: original, selectedVineyard: selected, serverID: nil,
            serverVineyard: nil, deletedAt: nil), .unattributed)
    }

    func testDeletedOriginalRecommendsReconciliationWithoutForcingIt() {
        let original = item(kind: .tripDeletion)
        let options = GuidedSyncCorrectionPolicy.available(for: original, server: .deleted)
        XCTAssertEqual(GuidedSyncRepairSuggestion.choose(
            available: options, server: .deleted, current: .privateReview), .reviewLegacyDeleted)
        XCTAssertEqual(GuidedSyncRepairSuggestion.choose(
            available: options, server: .deleted, current: .verifyCancellation), .verifyCancellation)
        XCTAssertEqual(GuidedSyncRepairSuggestion.choose(
            available: [.privateReview], server: .notVisible, current: .privateReview), .privateReview)
        let protected = item(kind: .protectedQueue, scoped: false)
        XCTAssertEqual(GuidedSyncRepairSuggestion.choose(
            available: GuidedSyncCorrectionPolicy.available(for: protected, server: .deleted),
            server: .deleted, current: .privateReview), .reviewLegacyDeleted)
    }

    func testDeletedDependentNeverOffersOrdinaryRetryOrQuantityMutation() {
        let kinds: [GuidedSyncRepairIssue.Kind] =
            [.tankActual, .sprayRecord, .trackedSprayCompletion]
        for kind in kinds {
            let options = GuidedSyncCorrectionPolicy.available(for: item(kind: kind), server: .deleted)
            XCTAssertFalse(options.contains(.retryExisting))
            XCTAssertFalse(options.contains(.correctPendingActualUse))
            XCTAssertFalse(options.contains(.amendActualUse))
        }
    }

    func testActualAndSprayRetryOnlyAfterExactParentScopeReadback() {
        let kinds: [GuidedSyncRepairIssue.Kind] = [.tankActual, .sprayRecord]
        for kind in kinds {
            let record = item(kind: kind)
            XCTAssertFalse(GuidedSyncCorrectionPolicy.available(for: record, server: .deleted)
                .contains(.retryExisting))
            XCTAssertTrue(GuidedSyncCorrectionPolicy.available(for: record, server: .active)
                .contains(.retryExisting))
        }
    }
}
