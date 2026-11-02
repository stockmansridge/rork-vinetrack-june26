import Foundation
import XCTest
@testable import VineTrack

/// Issue #43 / build 202: legacy Trip upload queue is global, while the app
/// applies only the currently selected vineyard's Trip cache slice.
/// These regressions must never require production data or network access.
final class TripQueuedUploadScopeTests: XCTestCase {
    func testCurrentVineyardOriginalEligibleOnlyWhenPresentInSelectedSlice() {
        let vineyard = UUID(), id = UUID()
        let status = TripQueuedUploadScope.classify(
            tripId: id, selectedVineyardId: vineyard,
            selectedTrips: [id: vineyard], persistedTrips: [id: vineyard])
        XCTAssertEqual(status, .selectedSlice)
        XCTAssertTrue(status.eligibleForCurrentVineyardUpload)
    }

    func testOtherLocallyCachedVineyardNeverGetsUploadedUnderCurrentVineyard() {
        let selected = UUID(), testing = UUID(), foreign = UUID()
        let status = TripQueuedUploadScope.classify(
            tripId: foreign, selectedVineyardId: selected,
            selectedTrips: [:], persistedTrips: [foreign: testing])
        XCTAssertEqual(status, .persistedOtherVineyard)
        XCTAssertFalse(status.eligibleForCurrentVineyardUpload)
    }

    func testSnapshotForCurrentVineyardNotLoadedCannotBeRecreatedFromMetadata() {
        let vineyard = UUID(), original = UUID()
        let status = TripQueuedUploadScope.classify(
            tripId: original, selectedVineyardId: vineyard,
            selectedTrips: [:], persistedTrips: [original: vineyard])
        XCTAssertEqual(status, .persistedCurrentVineyardNotLoaded)
        XCTAssertFalse(status.eligibleForCurrentVineyardUpload)
    }

    func testAbsentSnapshotDoesNotBecomeRetryableUploadOrDeletionAcknowledgement() {
        let missing = UUID()
        let status = TripQueuedUploadScope.classify(
            tripId: missing, selectedVineyardId: UUID(),
            selectedTrips: [:], persistedTrips: [:])
        XCTAssertEqual(status, .noLocalSnapshot)
        XCTAssertFalse(status.eligibleForCurrentVineyardUpload)
    }

    func testLocalForeignVineyardScopeWinsOverSelectedSliceMislabelling() {
        let selected = UUID(), other = UUID(), id = UUID()
        let status = TripQueuedUploadScope.classify(
            tripId: id, selectedVineyardId: selected,
            selectedTrips: [id: other], persistedTrips: [id: selected])
        XCTAssertEqual(status, .persistedOtherVineyard)
        XCTAssertFalse(status.eligibleForCurrentVineyardUpload)
    }

    func testGlobalLegacyFailuresNeverBecomeSelectedVineyardFailureOrSuccess() {
        let selected = UUID(), other = UUID(), selectedTrip = UUID(), foreign = UUID(), missing = UUID()
        let result = TripQueuedScopeSummary.evaluate(
            queuedIds: [selectedTrip, foreign, missing], failedIds: [foreign, missing],
            selectedVineyardId: selected,
            visibleTripVineyards: [selectedTrip: selected, foreign: other]
        )
        XCTAssertEqual(result.selectedQueuedCount, 1)
        XCTAssertEqual(result.outsideSelectedQueuedCount, 2)
        XCTAssertEqual(result.selectedFailedCount, 0, "Foreign failure must not poison current-vineyard sync")
        XCTAssertEqual(result.unresolvedCount, 3, "Original global queue must remain visibly unresolved")

        let currentFailed = TripQueuedScopeSummary.evaluate(
            queuedIds: [selectedTrip, foreign], failedIds: [selectedTrip, foreign],
            selectedVineyardId: selected, visibleTripVineyards: [selectedTrip: selected, foreign: other])
        XCTAssertEqual(currentFailed.selectedFailedCount, 1)
        XCTAssertEqual(currentFailed.outsideSelectedQueuedCount, 1)
    }

    func testRemoteSoftDeletionCannotDiscardUnresolvedOriginalUpload() {
        XCTAssertFalse(TripServerTombstonePolicy.mayApplyRemoteDeletion(
            hasOriginalPendingUpload: true))
        XCTAssertTrue(TripServerTombstonePolicy.mayApplyRemoteDeletion(
            hasOriginalPendingUpload: false))
    }

    func testTripHistoryAndNavigationNeverLeakOtherVineyardSnapshots() {
        let selected = UUID(), other = UUID()
        let selectedTrip = Trip(vineyardId: selected)
        let otherTrip = Trip(vineyardId: other)
        let visible = TripHistoryVineyardScope.visible(
            [otherTrip, selectedTrip], vineyardId: selected, excludingActive: nil)
        XCTAssertEqual(visible.map(\.id), [selectedTrip.id])
        XCTAssertFalse(TripHistoryVineyardScope.canOpen(otherTrip, vineyardId: selected))
        XCTAssertTrue(TripHistoryVineyardScope.canOpen(selectedTrip, vineyardId: selected))
        XCTAssertTrue(TripHistoryVineyardScope.visible(
            [otherTrip, selectedTrip], vineyardId: nil, excludingActive: nil).isEmpty)
        XCTAssertTrue(TripHistoryVineyardScope.visible(
            [otherTrip, selectedTrip], vineyardId: selected,
            excludingActive: selectedTrip.id).isEmpty)
    }

    func testCompletedServerTripReceiptRequiresExactOriginalEndAndTankEvidence() {
        let vineyard = UUID()
        let end = Date(timeIntervalSince1970: 1_792_000_000)
        let session = TankSession(tankNumber: 1, startTime: end.addingTimeInterval(-3600),
                                  endTime: end, pathsCovered: [12.5])
        let original = Trip(vineyardId: vineyard, endTime: end, isActive: false,
                            tankSessions: [session], tripFunction: "spraying")
        XCTAssertNil(CompletedTripReceiptAdmission.holdReason(local: original, remote: original))

        var differentEnd = original
        differentEnd.endTime = end.addingTimeInterval(60)
        XCTAssertEqual(CompletedTripReceiptAdmission.holdReason(
            local: original, remote: differentEnd), "TRIP_ORIGINAL_END_TIME_MISMATCH")

        var differentVineyard = original
        differentVineyard.vineyardId = UUID()
        XCTAssertEqual(CompletedTripReceiptAdmission.holdReason(
            local: original, remote: differentVineyard), "TRIP_ORIGINAL_IDENTITY_MISMATCH")

        var changedTank = original
        changedTank.tankSessions[0].endTime = end.addingTimeInterval(-120)
        XCTAssertEqual(CompletedTripReceiptAdmission.holdReason(
            local: original, remote: changedTank), "TRIP_LOCAL_TANK_SESSION_DIFFERS")

        var reopenedRemote = original
        reopenedRemote.isActive = true
        XCTAssertEqual(CompletedTripReceiptAdmission.holdReason(
            local: original, remote: reopenedRemote), "TRIP_ORIGINAL_END_TIME_MISMATCH")
    }

    @MainActor func testScopeClassificationDoesNotMutatePersistedQueue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TripQueuedScope-\(UUID().uuidString)")
        // PersistenceStore intentionally does not create directories.
        // Mirror the real app's pre-existing VineTrackData directory; otherwise
        // its legacy non-throwing save discards an ENOENT and this test falsely
        // reports a queue-loss regression before any scope code runs.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = TripSyncMetadata(persistence: PersistenceStore(directory: directory))
        let foreign = UUID()
        metadata.markDirty(foreign, at: Date(timeIntervalSince1970: 1_700_000_000))
        let before = metadata.pendingUpserts
        let status = TripQueuedUploadScope.classify(
            tripId: foreign, selectedVineyardId: UUID(),
            selectedTrips: [:], persistedTrips: [:])
        XCTAssertFalse(status.eligibleForCurrentVineyardUpload)
        XCTAssertEqual(metadata.pendingUpserts, before)
        let reloaded = TripSyncMetadata(persistence: PersistenceStore(directory: directory))
        XCTAssertEqual(reloaded.pendingUpserts, before)
    }
}
