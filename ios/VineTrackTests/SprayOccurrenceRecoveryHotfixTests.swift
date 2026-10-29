import Foundation
import XCTest
@testable import VineTrack

final class SprayOccurrenceRecoveryHotfixTests: XCTestCase {
    @MainActor func testOccurrenceWalReleasesOnlyLegacyGateWithExactDurableParentAndRetainsEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID(), vineyard = UUID(), block = UUID()
        let journalRoot = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("TripOccurrenceJournals").appendingPathComponent(owner.uuidString.lowercased())
        defer { try? FileManager.default.removeItem(at: journalRoot) }
        let persistence = PersistenceStore(directory: root)
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyard
        store.currentUserIdProvider = { owner }
        let scope = LegacySpraySaveRecovery.Scope(actor: owner, session: UUID(), vineyard: vineyard)
        store.legacySprayScopeProvider = { scope }
        let raw = try TripOccurrencePlanner.commit([
            .init(vineyardId: vineyard, blockId: block, blockName: "Synthetic", label: 1.5, rows: [])
        ], vineyardId: vineyard)
        let trip = Trip(vineyardId: vineyard, paddockId: block, paddockName: "Synthetic", paddockIds: [block], isActive: false, rowSequence: [1.5], occurrenceCoverage: raw)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard, notes: "Frozen original recipe")
        try store.saveSprayForLater(record: record, trip: trip)
        XCTAssertTrue(try store.isLegacySpraySyncHeld(trip: trip.id), "A missing parent must remain held")
        let wal = LegacySpraySaveRecovery(persistence: persistence)
        let before = try wal.attempts()
        let repository = SupabaseTripSyncRepository()
        try repository.prepareOccurrenceCreation(BackendTrip.upsert(from: trip, createdBy: owner, clientUpdatedAt: trip.startTime), ownerId: owner)
        let journal = try TripOccurrenceJournal(scope: .init(ownerId: owner.uuidString.lowercased(), vineyardId: vineyard.uuidString.lowercased(), tripId: trip.id.uuidString.lowercased()))
        let create = try XCTUnwrap(journal.load()?.pending.first)
        let activation = try journal.activate(.object(["startTime": .string("2026-10-29T02:07:00Z")]))
        try journal.hold("OCCURRENCE_REVISION_CONFLICT")
        let retained = try XCTUnwrap(journal.load())
        XCTAssertFalse(try store.isLegacySpraySyncHeld(trip: trip.id))
        XCTAssertFalse(try store.isLegacySpraySyncHeld(record: record.id))
        try store.requireLegacySpraySyncAdmission(trip: trip.id)
        try store.requireLegacySpraySweepCompletion(vineyard: vineyard)
        XCTAssertEqual(try store.legacySprayHeldCount(vineyard: vineyard), 0)
        XCTAssertTrue(try store.acceptedLegacySprayPairs(vineyard: vineyard).isEmpty, "No legacy acceptance or parent acknowledgement fabricated")
        XCTAssertFalse(journal.canOperate(retained), "The actual occurrence conflict is not bypassed")
        XCTAssertEqual(retained.pending.map(\.id), [create.id, activation.id])
        try await wal.replay(scope: scope, isCurrent: { true }) { _, _ in
            XCTFail("Occurrence evidence sent to a legacy receipt RPC")
            return Data()
        }
        XCTAssertEqual(try wal.attempts(), before)
        XCTAssertEqual(try journal.load(), retained)
        XCTAssertEqual(store.trips, [trip])
        XCTAssertEqual(store.sprayRecords, [record])
        // A different retained creation body must never release the legacy gate.
        var changed = trip; changed.tripTitle = "Different original intent"
        var mismatch = LegacySpraySaveRecovery.Attempt(scope: scope, record: record, trip: changed)
        mismatch.localComplete = true
        XCTAssertTrue(try wal.requiresLegacyReceipt(mismatch))
    }

    @MainActor func testNewStartPreflightDoesNotMintJournalForHistoricalTripAndStillBlocksUncertainCreate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID(), vineyard = UUID(), block = UUID()
        let journalRoot = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("TripOccurrenceJournals").appendingPathComponent(owner.uuidString.lowercased())
        defer { try? FileManager.default.removeItem(at: journalRoot) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root))
        store.currentUserIdProvider = { owner }; store.selectedVineyardId = vineyard
        let raw = try TripOccurrencePlanner.commit([
            .init(vineyardId: vineyard, blockId: block, blockName: "Historical", label: 1.5, rows: [])
        ], vineyardId: vineyard)
        let trip = Trip(vineyardId: vineyard, paddockName: "Historical", isActive: false, occurrenceCoverage: raw)
        store.trips = [trip]
        let tracking = TripTrackingService()
        tracking.configure(store: store, locationService: LocationService())
        let journal = try TripOccurrenceJournal(scope: .init(ownerId: owner.uuidString.lowercased(), vineyardId: vineyard.uuidString.lowercased(), tripId: trip.id.uuidString.lowercased()))
        try tracking.requireResolvedOccurrenceStarts()
        XCTAssertNil(try journal.load(), "Duplicate checking must not fabricate unresolved evidence")
        try SupabaseTripSyncRepository().prepareOccurrenceCreation(BackendTrip.upsert(from: trip, createdBy: owner, clientUpdatedAt: trip.startTime), ownerId: owner)
        let retained = try journal.load()
        XCTAssertThrowsError(try tracking.requireResolvedOccurrenceStarts())
        XCTAssertEqual(try journal.load(), retained)
        XCTAssertEqual(store.trips, [trip])
    }

    @MainActor func testSavedOccurrenceReachesDedicatedRecoveryRatherThanLegacyReceiptGate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: root))
        let owner = UUID(), vineyard = UUID(), block = UUID()
        store.selectedVineyardId = vineyard
        store.currentUserIdProvider = { owner }
        store.legacySprayScopeProvider = { .init(actor: owner, session: owner, vineyard: vineyard) }
        let coverage = try TripOccurrencePlanner.commit([
            .init(vineyardId: vineyard, blockId: block, blockName: "Synthetic retained block", label: 1.5, rows: [])
        ], vineyardId: vineyard)
        let trip = Trip(vineyardId: vineyard, paddockId: block, paddockName: "Synthetic retained block", paddockIds: [block], isActive: false, rowSequence: [1.5], occurrenceCoverage: coverage)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard, tanks: [SprayTank(tankNumber: 1, waterVolume: 400, sprayRatePerHa: 200, chemicals: [SprayChemical(name: "Synthetic product", volumePerTank: 400, ratePer100L: 100)])])
        try store.saveSprayForLater(record: record, trip: trip)
        let tracking = TripTrackingService()
        tracking.configure(store: store, locationService: LocationService())
        let completed = expectation(description: "Dedicated recovery rejects absent authenticated owner")
        tracking.activateSavedTrip(trip) { started in
            XCTAssertFalse(started)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 3)
        // No auth is supplied: reaching this scope error proves the occurrence branch ran.
        XCTAssertEqual(tracking.errorMessage, TripOccurrenceCoverage.Failure.scopeConflict.localizedDescription)
        XCTAssertEqual(store.trips, [trip])
        XCTAssertEqual(store.sprayRecords, [record])
        XCTAssertNil(store.deviceActiveTripId)
    }
    @MainActor func testQueuedOccurrenceRestoresMissingTankRecipeFromOriginalCompletedWAL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let owner = UUID(), vineyard = UUID(), block = UUID()
        store.selectedVineyardId = vineyard
        store.currentUserIdProvider = { owner }
        store.legacySprayScopeProvider = {
            LegacySpraySaveRecovery.Scope(actor: owner, session: owner, vineyard: vineyard)
        }
        let coverage = try TripOccurrencePlanner.commit([
            .init(vineyardId: vineyard, blockId: block, blockName: "Queued",
                  label: 1.5, rows: [])
        ], vineyardId: vineyard)
        let trip = Trip(vineyardId: vineyard, paddockId: block, paddockName: "Queued",
            paddockIds: [block], isActive: false, rowSequence: [1.5],
            occurrenceCoverage: coverage)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard,
            tanks: [SprayTank(tankNumber: 1, waterVolume: 420,
                chemicals: [SprayChemical(name: "Synthetic", ratePer100L: 100)])],
            notes: "Original frozen tank recipe")
        try store.saveSprayForLater(record: record, trip: trip)
        let original = try LegacySpraySaveRecovery(persistence: persistence).attempts()
        XCTAssertEqual(original.count, 1)
        XCTAssertTrue(original[0].localComplete)
        // Simulate a newer local cache whose spray-list file lost the row
        // while the immutable paired-save WAL and trip are still present.
        try store.sprayRepo.saveRecordsSliceOrThrow([], for: vineyard)
        store.sprayRecords = []
        XCTAssertTrue(try store.restoreQueuedOccurrenceSprayRecordIfRetained(tripId: trip.id))
        XCTAssertEqual(store.sprayRecords, [record])
        XCTAssertEqual(store.trips, [trip])
        XCTAssertEqual(try LegacySpraySaveRecovery(persistence: persistence).attempts(), original)
        XCTAssertTrue(try store.restoreQueuedOccurrenceSprayRecordIfRetained(tripId: trip.id))
        XCTAssertEqual(store.sprayRecords, [record])
    }

    @MainActor func testQueuedOccurrenceNeverOverwritesDifferentLinkedSprayRecipe() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        let owner = UUID(), vineyard = UUID(), block = UUID()
        store.selectedVineyardId = vineyard
        store.currentUserIdProvider = { owner }
        store.legacySprayScopeProvider = {
            LegacySpraySaveRecovery.Scope(actor: owner, session: owner, vineyard: vineyard)
        }
        let coverage = try TripOccurrencePlanner.commit([
            .init(vineyardId: vineyard, blockId: block, blockName: "Queued",
                  label: 1.5, rows: [])
        ], vineyardId: vineyard)
        let trip = Trip(vineyardId: vineyard, paddockId: block, paddockName: "Queued",
            paddockIds: [block], isActive: false, rowSequence: [1.5],
            occurrenceCoverage: coverage)
        let original = SprayRecord(tripId: trip.id, vineyardId: vineyard,
            notes: "Original")
        try store.saveSprayForLater(record: original, trip: trip)
        let different = SprayRecord(tripId: trip.id, vineyardId: vineyard,
            notes: "Different linked recipe")
        store.sprayRecords = [different]
        XCTAssertFalse(try store.restoreQueuedOccurrenceSprayRecordIfRetained(tripId: trip.id))
        XCTAssertEqual(store.sprayRecords, [different])
        XCTAssertEqual(store.trips, [trip])
    }

}
