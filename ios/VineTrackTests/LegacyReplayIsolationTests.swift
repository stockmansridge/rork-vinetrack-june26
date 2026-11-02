import Foundation
import XCTest
@testable import VineTrack

final class LegacyReplayIsolationTests: XCTestCase {
    @MainActor private func fixture() throws -> (URL, PersistenceStore, Data, Trip, SprayRecord) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let disk = PersistenceStore(directory: directory)
        let vineyard = UUID()
        let trip = Trip(vineyardId: vineyard, paddockName: "Retained fixture", isActive: false)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard)
        let attempt = LegacySpraySaveRecovery.Attempt(scope: .init(actor: UUID(), session: UUID(), vineyard: vineyard), record: record, trip: trip)
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(attempt)) as? [String: Any])
        row["localComplete"] = "incompatible retained payload"
        let bytes = try JSONSerialization.data(withJSONObject: [row], options: [.sortedKeys])
        try bytes.write(to: directory.appendingPathComponent(LegacySpraySaveRecovery.key + ".json"))
        return (directory, disk, bytes, trip, record)
    }
    @MainActor func testIncompatibleOriginalIsScopedAndRawBytesAreUnchanged() throws {
        let (directory, disk, bytes, trip, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = LegacySpraySaveRecovery(persistence: disk)
        XCTAssertThrowsError(try journal.attempts())
        XCTAssertFalse(try journal.contains(trip: UUID()))
        XCTAssertTrue(try journal.contains(trip: trip.id))
        XCTAssertTrue(try journal.contains(record: record.id))
        XCTAssertEqual(try disk.retainedBytesForInspection(key: LegacySpraySaveRecovery.key), bytes)
        XCTAssertEqual(journal.replayInspection().held.count, 1)
        XCTAssertTrue(journal.replayInspection().held[0].attributable)
    }
    @MainActor func testUnknownIdentityNeverPermitsUnrelatedReplay() throws {
        for bytes in [Data("bad".utf8), Data("[7]".utf8), Data("[{\"scope\":{}}]".utf8)] {
            XCTAssertEqual(LegacyReplayIsolation.inspect(bytes).blocker(trip: UUID(), record: UUID()), "LEGACY_IDENTITY_UNRESOLVED")
        }
        XCTAssertNil(LegacyReplayIsolation.inspect(nil).blocker(trip: UUID(), record: nil))
    }
    @MainActor func testNestedReferencesStayProtected() throws {
        let (directory, _, bytes, trip, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = LegacyReplayIsolation.inspect(bytes)
        XCTAssertEqual(index.blocker(trip: trip.id, record: nil), "LEGACY_SAME_TRIP_CONFLICT")
        XCTAssertNil(index.blocker(trip: UUID(), record: UUID()))
        XCTAssertNotEqual(index.fingerprint, LegacyReplayIsolation.inspect(bytes + Data(" ".utf8)).fingerprint)
    }
    @MainActor func testReconciliationPreflightDoesNotAbortIndependentAdmissionOrAcknowledgeOriginal() throws {
        let (directory, disk, bytes, trip, record) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MigratedDataStore(persistence: disk)
        store.selectedVineyardId = trip.vineyardId
        XCTAssertNoThrow(try store.reconcileLegacySpraySaves(isolatingHeldFailures: true))
        XCTAssertFalse(try store.isLegacySpraySyncHeld(trip: UUID()))
        XCTAssertTrue(try store.isLegacySpraySyncHeld(trip: trip.id))
        XCTAssertTrue(try store.isLegacySpraySyncHeld(record: record.id))
        XCTAssertTrue(try store.unchangedAcceptedLegacySprays().isEmpty)
        XCTAssertTrue(try store.acceptedLegacySprayPairs(vineyard: trip.vineyardId).isEmpty)
        XCTAssertEqual(try store.legacySprayHeldCount(vineyard: trip.vineyardId), 1)
        XCTAssertEqual(try disk.retainedBytesForInspection(key: LegacySpraySaveRecovery.key), bytes)
        XCTAssertThrowsError(try store.requireLegacySpraySyncAdmission(trip: trip.id))
        XCTAssertNoThrow(try store.requireLegacySpraySyncAdmission(trip: UUID()))
    }
    @MainActor func testInspectionDoesNotCreateMissingDirectoryOrEmitDecodeEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = PersistenceStore(directory: root)
        var decodeFailures = 0
        disk.onDecodeFailure = { _, _ in decodeFailures += 1 }
        XCTAssertTrue(LegacySpraySaveRecovery(persistence: disk).replayInspection().held.isEmpty)
        XCTAssertEqual(decodeFailures, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
