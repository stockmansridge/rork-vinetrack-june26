import XCTest
@testable import VineTrack

final class SpraySaveForLaterTests: XCTestCase {
    @MainActor func testSuccessfulLegacySavePersistsInactiveTripAndRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let vineyard = UUID()
        store.selectedVineyardId = vineyard
        let scope = LegacySpraySaveRecovery.Scope(actor: UUID(), session: UUID(), vineyard: vineyard)
        store.legacySprayScopeProvider = { scope }
        let trip = Trip(vineyardId: vineyard, paddockName: "Synthetic", startTime: Date(timeIntervalSince1970: 100), isActive: false)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard, date: Date(timeIntervalSince1970: 100), startTime: Date(timeIntervalSince1970: 100))
        try store.saveSprayForLater(record: record, trip: trip)
        try store.saveSprayForLater(record: record, trip: trip)
        XCTAssertEqual(SprayRepository(persistence: persistence).loadAllRecords(), [record])
        XCTAssertEqual(TripRepository(persistence: persistence).loadAll(), [trip])
        XCTAssertNil(store.deviceActiveTripId)
    }

    @MainActor func testExplicitRecordFailureCreatesNoTripOrSuccessPublication() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let vineyard = UUID()
        store.selectedVineyardId = vineyard
        let scope = LegacySpraySaveRecovery.Scope(actor: UUID(), session: UUID(), vineyard: vineyard)
        store.legacySprayScopeProvider = { scope }
        let trip = Trip(vineyardId: vineyard, paddockName: "Synthetic", isActive: false)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard)
        var publications = 0
        store.onSprayRecordChanged = { _ in publications += 1 }
        store.onTripChanged = { _ in publications += 1 }
        persistence.durableSaveFailureForTesting = { _ in SprayTankActualValidationError.localSaveFailed }
        XCTAssertThrowsError(try store.saveSprayForLater(record: record, trip: trip))
        XCTAssertFalse(store.addSprayRecord(record))
        XCTAssertTrue(store.trips.isEmpty)
        XCTAssertTrue(store.sprayRecords.isEmpty)
        XCTAssertEqual(publications, 0)
        XCTAssertTrue(TripRepository(persistence: persistence).loadAll().isEmpty)
    }

    @MainActor func testUncertainRecordAcknowledgementRetainsExactIdentityForRetry() throws {
        let vineyard = UUID()
        let trip = Trip(vineyardId: vineyard, paddockName: "Synthetic", isActive: false)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard)
        var stored: [SprayRecord] = []
        var trips: [Trip] = []
        XCTAssertThrowsError(try SpraySaveForLaterCoordinator.save(record: record, trip: trip, saveRecord: {
            stored = [$0]
            throw SprayTankActualValidationError.localSaveFailed
        }, saveTrip: { trips.append($0) }))
        XCTAssertEqual(stored, [record])
        XCTAssertTrue(trips.isEmpty)
        try SpraySaveForLaterCoordinator.save(record: record, trip: trip, saveRecord: {
            XCTAssertEqual(stored, [$0])
        }, saveTrip: { trips = [$0] })
        XCTAssertEqual(stored, [record])
        XCTAssertEqual(trips, [trip])
        XCTAssertFalse(trips[0].isActive)
    }

    @MainActor func testTripWriteFailureRetryDoesNotDuplicateDurableRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let vineyard = UUID()
        store.selectedVineyardId = vineyard
        let scope = LegacySpraySaveRecovery.Scope(actor: UUID(), session: UUID(), vineyard: vineyard)
        store.legacySprayScopeProvider = { scope }
        let trip = Trip(vineyardId: vineyard, paddockName: "Synthetic", startTime: Date(timeIntervalSince1970: 100), isActive: false)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard, date: Date(timeIntervalSince1970: 100), startTime: Date(timeIntervalSince1970: 100))
        persistence.durableSaveFailureForTesting = { key in key == TripRepository.storageKey ? SprayTankActualValidationError.localSaveFailed : nil }
        XCTAssertThrowsError(try store.saveSprayForLater(record: record, trip: trip))
        XCTAssertEqual(store.sprayRecords, [record])
        XCTAssertTrue(store.trips.isEmpty)
        persistence.durableSaveFailureForTesting = nil
        try store.saveSprayForLater(record: record, trip: trip)
        XCTAssertEqual(store.sprayRecords, [record])
        XCTAssertEqual(store.trips, [trip])
    }

    @MainActor func testEditDiskFailureNeverPublishesSuccessOrChangesOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let vineyard = UUID()
        store.selectedVineyardId = vineyard
        let scope = LegacySpraySaveRecovery.Scope(actor: UUID(), session: UUID(), vineyard: vineyard)
        store.legacySprayScopeProvider = { scope }
        let original = SprayRecord(vineyardId: vineyard, date: Date(timeIntervalSince1970: 100), startTime: Date(timeIntervalSince1970: 100), notes: "Original")
        XCTAssertTrue(store.addSprayRecord(original))
        var edited = original
        edited.notes = "Edited"
        var publications = 0
        store.onSprayRecordChanged = { _ in publications += 1 }
        persistence.durableSaveFailureForTesting = { _ in SprayTankActualValidationError.localSaveFailed }
        XCTAssertFalse(store.updateSprayRecord(edited))
        XCTAssertEqual(store.sprayRecords, [original])
        XCTAssertEqual(SprayRepository(persistence: persistence).loadAllRecords(), [original])
        XCTAssertEqual(publications, 0)
        persistence.durableSaveFailureForTesting = nil
        XCTAssertTrue(store.updateSprayRecord(edited))
        XCTAssertEqual(SprayRepository(persistence: persistence).loadAllRecords(), [edited])
        XCTAssertEqual(publications, 1)
        store.selectedVineyardId = UUID()
        XCTAssertFalse(store.updateSprayRecord(edited))
        XCTAssertEqual(publications, 1)
    }

    @MainActor func testStartupReconcilesEveryLocalPersistenceBoundaryBeforePublication() throws {
        for boundary in ["intent", "record", "trip", "completion"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let p = PersistenceStore(directory: root)
            let vineyard = UUID()
            let scope = LegacySpraySaveRecovery.Scope(actor: UUID(), session: UUID(), vineyard: vineyard)
            let original = MigratedDataStore(persistence: p)
            original.selectedVineyardId = vineyard; original.legacySprayScopeProvider = { scope }
            let trip = Trip(vineyardId: vineyard, paddockName: "Frozen original", startTime: Date(timeIntervalSince1970: 100), isActive: false)
            let record = SprayRecord(tripId: trip.id, vineyardId: vineyard, date: Date(timeIntervalSince1970: 100), startTime: Date(timeIntervalSince1970: 100), notes: "Exact original")
            var commits = 0
            p.durableSaveFailureForTesting = { key in
                if key == LegacySpraySaveRecovery.key { commits += 1 }
                let fail = (boundary == "intent" && key == LegacySpraySaveRecovery.key && commits == 1) ||
                    (boundary == "record" && key == SprayRepository.recordsKey) ||
                    (boundary == "trip" && key == TripRepository.storageKey) ||
                    (boundary == "completion" && key == LegacySpraySaveRecovery.key && commits == 2)
                return fail ? SprayTankActualValidationError.localSaveFailed : nil
            }
            var publications = 0
            original.onTripChanged = { _ in publications += 1 }
            original.onSprayRecordChanged = { _ in publications += 1 }
            XCTAssertThrowsError(try original.saveSprayForLater(record: record, trip: trip), boundary)
            XCTAssertEqual(publications, 0, boundary)
            let restarted = MigratedDataStore(persistence: PersistenceStore(directory: root))
            restarted.selectedVineyardId = vineyard; restarted.legacySprayScopeProvider = { scope }
            restarted.reloadCurrentVineyardData()
            if boundary == "intent" {
                XCTAssertTrue(restarted.trips.isEmpty && restarted.sprayRecords.isEmpty)
            } else {
                XCTAssertEqual(restarted.trips, [trip]); XCTAssertEqual(restarted.sprayRecords, [record])
                try restarted.reconcileLegacySpraySaves()
                XCTAssertEqual(restarted.trips.count, 1); XCTAssertEqual(restarted.sprayRecords.count, 1)
                XCTAssertThrowsError(try restarted.requireLegacySpraySyncAdmission(record: record.id))
                XCTAssertThrowsError(try restarted.requireLegacySpraySyncAdmission(trip: trip.id))
                XCTAssertNil(restarted.deviceActiveTripId)
            }
        }
    }

    @MainActor func testChangedRecordAndForeignSessionAreHeldWithoutInventedRepair() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = PersistenceStore(directory: root)
        let vineyard = UUID()
        let scope = LegacySpraySaveRecovery.Scope(actor: UUID(), session: UUID(), vineyard: vineyard)
        let trip = Trip(vineyardId: vineyard, paddockName: "Original", isActive: false)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard, notes: "Original")
        try LegacySpraySaveRecovery(persistence: p).prepare(scope: scope, record: record, trip: trip)
        let store = MigratedDataStore(persistence: p); store.selectedVineyardId = vineyard
        for foreign in [LegacySpraySaveRecovery.Scope(actor: UUID(), session: scope.session, vineyard: vineyard),
                        LegacySpraySaveRecovery.Scope(actor: scope.actor, session: UUID(), vineyard: vineyard)] {
            store.legacySprayScopeProvider = { foreign }
            try store.reconcileLegacySpraySaves()
            XCTAssertTrue(store.trips.isEmpty && store.sprayRecords.isEmpty)
            XCTAssertThrowsError(try store.requireLegacySpraySyncAdmission(record: record.id))
        }
        var changed = record; changed.notes = "Changed"
        try store.sprayRepo.saveRecordsSliceOrThrow([changed], for: vineyard)
        store.sprayRecords = [changed]; store.legacySprayScopeProvider = { scope }
        XCTAssertThrowsError(try store.reconcileLegacySpraySaves())
        XCTAssertEqual(store.sprayRecords, [changed]); XCTAssertTrue(store.trips.isEmpty)
        XCTAssertEqual(try LegacySpraySaveRecovery(persistence: p).attempts().first?.record, record)
    }

    @MainActor func testProductionSyncAndInitialFallbackContainOnlyTheRetainedPair() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = PersistenceStore(directory: root)
        let store = MigratedDataStore(persistence: p)
        let vineyard = UUID(); store.selectedVineyardId = vineyard
        let auth = NewBackendAuthService()
        let records = LegacyRecordSyncProbe(); let trips = LegacyTripSyncProbe()
        let recordSync = SprayRecordSyncService(repository: records, metadata: SprayRecordSyncMetadata(persistence: p))
        let tripSync = TripSyncService(repository: trips, metadata: TripSyncMetadata(persistence: p))
        recordSync.configure(store: store, auth: auth); tripSync.configure(store: store, auth: auth)
        let scope = LegacySpraySaveRecovery.Scope(actor: UUID(), session: UUID(), vineyard: vineyard)
        store.legacySprayScopeProvider = { scope }
        let trip = Trip(vineyardId: vineyard, paddockName: "Original", isActive: false)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard)
        try store.saveSprayForLater(record: record, trip: trip)
        try await recordSync.pushLocalSprayRecords(vineyardId: vineyard)
        try await tripSync.pushLocalTrips(vineyardId: vineyard)
        try await recordSync.pullRemoteSprayRecords(vineyardId: vineyard)
        try await tripSync.pullRemoteTrips(vineyardId: vineyard)
        recordSync.markSprayRecordDeleted(record.id); tripSync.markTripDeleted(trip.id)
        try await recordSync.pushLocalSprayRecords(vineyardId: vineyard)
        try await tripSync.pushLocalTrips(vineyardId: vineyard)
        XCTAssertTrue(records.writes.isEmpty && trips.writes.isEmpty)
        XCTAssertTrue(records.deletes.isEmpty && trips.deletes.isEmpty)
        await tripSync.setWorkTaskLink(tripId: trip.id, workTaskId: UUID())
        XCTAssertTrue(trips.writes.isEmpty)
        XCTAssertEqual(store.trips.first { $0.id == trip.id }, trip)
        XCTAssertFalse(tripSync.isParentEstablished(trip.id))
        XCTAssertThrowsError(try store.requireLegacySpraySweepCompletion(vineyard: vineyard))
        let unrelated = SprayRecord(vineyardId: vineyard, notes: "Unrelated legacy record")
        XCTAssertTrue(store.addSprayRecord(unrelated))
        try await recordSync.pushLocalSprayRecords(vineyardId: vineyard)
        XCTAssertEqual(records.writes, [unrelated.id])
        // A retained local conflict must not prevent a second unrelated upload.
        var changed = record; changed.notes = "Conflicting projection"
        store.sprayRecords = store.sprayRecords.map { $0.id == record.id ? changed : $0 }
        let journal = LegacySpraySaveRecovery(persistence: p)
        // The original exact pair and global identity hold survive foreign account scope.
        store.legacySprayScopeProvider = { LegacySpraySaveRecovery.Scope(actor: UUID(), session: UUID(), vineyard: vineyard) }
        let historical = Trip(vineyardId: vineyard, paddockName: "Historical unrelated", isActive: true)
        store.trips.append(historical); tripSync.markTripDirty(historical.id)
        try await tripSync.pushLocalTrips(vineyardId: vineyard)
        XCTAssertEqual(trips.writes, [historical.id])
        XCTAssertEqual(try store.legacySprayHeldCount(vineyard: vineyard), 1)
        XCTAssertTrue(try journal.contains(trip: trip.id))
        XCTAssertFalse(try journal.contains(trip: historical.id))
        XCTAssertEqual(try LegacySpraySaveRecovery(persistence: p).attempts().first?.record, record)
    }

    @MainActor func testIncompleteRepairConflictCannotVetoUnrelatedUploadOrReleaseOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = PersistenceStore(directory: root)
        let store = MigratedDataStore(persistence: p)
        let vineyard = UUID(); store.selectedVineyardId = vineyard
        let scope = LegacySpraySaveRecovery.Scope(actor: UUID(), session: UUID(), vineyard: vineyard)
        let trip = Trip(vineyardId: vineyard, paddockName: "Original", isActive: false)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard, notes: "Original")
        let journal = LegacySpraySaveRecovery(persistence: p)
        try journal.prepare(scope: scope, record: record, trip: trip)
        var changed = record; changed.notes = "Conflict"
        store.sprayRecords = [changed]
        let records = LegacyRecordSyncProbe()
        let sync = SprayRecordSyncService(repository: records, metadata: SprayRecordSyncMetadata(persistence: p))
        sync.configure(store: store, auth: NewBackendAuthService())
        store.legacySprayScopeProvider = { scope }
        let unrelated = SprayRecord(vineyardId: vineyard, notes: "Unrelated")
        XCTAssertTrue(store.addSprayRecord(unrelated))
        try await sync.pushLocalSprayRecords(vineyardId: vineyard)
        XCTAssertEqual(records.writes, [unrelated.id])
        XCTAssertEqual(store.sprayRecords.first { $0.id == record.id }, changed)
        XCTAssertEqual(try journal.attempts().first?.record, record)
        XCTAssertFalse(try journal.attempts().first?.localComplete ?? true)
        XCTAssertThrowsError(try store.requireLegacySpraySyncAdmission(record: record.id))
        XCTAssertFalse(sync.hasFailure(record.id))
    }

    @MainActor func testPlanningGateRefusesBeforeEitherWrite() {
        let vineyard = UUID()
        let trip = Trip(vineyardId: vineyard, paddockName: "Synthetic", isActive: false)
        var geometry = SprayApplicationSnapshot()
        geometry.planningIntent = SprayPlanningIntent(configuration: .overRow, method: .fullTank)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard, applicationGeometry: geometry)
        var writes = 0
        XCTAssertThrowsError(try SpraySaveForLaterCoordinator.save(record: record, trip: trip, saveRecord: { _ in writes += 1 }, saveTrip: { _ in writes += 1 }))
        XCTAssertEqual(writes, 0)
    }
    @MainActor func testVerifiedReceiptReleasesParentAndTaskLinkWithoutRecreatingOriginalPair() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = PersistenceStore(directory: root); let store = MigratedDataStore(persistence: p)
        let scope = LegacySpraySaveRecovery.Scope(actor: UUID(), session: UUID(), vineyard: UUID())
        store.selectedVineyardId = scope.vineyard
        let trips = LegacyTripSyncProbe(); let records = LegacyRecordSyncProbe(); let auth = NewBackendAuthService()
        let ts = TripSyncService(repository: trips, metadata: TripSyncMetadata(persistence: p))
        let rs = SprayRecordSyncService(repository: records, metadata: SprayRecordSyncMetadata(persistence: p))
        ts.configure(store: store, auth: auth); rs.configure(store: store, auth: auth)
        store.legacySprayScopeProvider = { scope }
        let trip = Trip(vineyardId: scope.vineyard, isActive: false)
        let record = SprayRecord(tripId: trip.id, vineyardId: scope.vineyard)
        try store.saveSprayForLater(record: record, trip: trip)
        XCTAssertFalse(ts.isParentEstablished(trip.id))
        await ts.setWorkTaskLink(tripId: trip.id, workTaskId: UUID()); XCTAssertTrue(trips.writes.isEmpty)
        let journal = LegacySpraySaveRecovery(persistence: p); let a = try XCTUnwrap(journal.attempts().first)
        let receipt = try JSONSerialization.data(withJSONObject: ["version": 1, "status": "accepted",
            "operation_id": try XCTUnwrap(a.rpc?.operation).uuidString.lowercased(), "vineyard_id": scope.vineyard.uuidString.lowercased(),
            "trip_id": trip.id.uuidString.lowercased(), "spray_record_id": record.id.uuidString.lowercased(),
            "request_sha256": String(repeating: "a", count: 64), "committed_at": "2026-10-15T03:00:01Z"])
        try await journal.replay(scope: scope, isCurrent: { true }) { _, _ in receipt }
        try await ts.pushLocalTrips(vineyardId: scope.vineyard)
        try await rs.pushLocalSprayRecords(vineyardId: scope.vineyard)
        try await ts.pullRemoteTrips(vineyardId: scope.vineyard)
        try await rs.pullRemoteSprayRecords(vineyardId: scope.vineyard)
        XCTAssertTrue(trips.writes.isEmpty && records.writes.isEmpty)
        XCTAssertTrue(ts.isParentEstablished(trip.id))
        try store.requireLegacySpraySyncAdmission(trip: trip.id)
        await ts.setWorkTaskLink(tripId: trip.id, workTaskId: UUID())
        XCTAssertEqual(trips.writes, [trip.id])
        // A later session or local edit must not reclassify the original as a generic CREATE.
        let newSession = LegacySpraySaveRecovery.Scope(actor: scope.actor, session: UUID(), vineyard: scope.vineyard)
        store.legacySprayScopeProvider = { newSession }
        store.sprayRecords[0].notes = "Later local edit"
        rs.markSprayRecordDirty(record.id); ts.markTripDirty(trip.id)
        try await ts.pushLocalTrips(vineyardId: scope.vineyard)
        try await rs.pushLocalSprayRecords(vineyardId: scope.vineyard)
        try await ts.pullRemoteTrips(vineyardId: scope.vineyard)
        try await rs.pullRemoteSprayRecords(vineyardId: scope.vineyard)
        XCTAssertEqual(trips.writes, [trip.id]); XCTAssertTrue(records.writes.isEmpty)
        XCTAssertEqual(try journal.attempts()[0].rpc, a.rpc)
    }
}

@MainActor private final class LegacyRecordSyncProbe: SprayRecordSyncRepositoryProtocol {
    var writes: [UUID] = []; var deletes: [UUID] = []
    func fetchSprayRecords(vineyardId: UUID, since: Date?) async throws -> [BackendSprayRecord] { [] }
    func fetchAllSprayRecords(vineyardId: UUID) async throws -> [BackendSprayRecord] { [] }
    func upsertSprayRecord(_ record: BackendSprayRecordUpsert) async throws { writes.append(record.id) }
    func upsertSprayRecords(_ records: [BackendSprayRecordUpsert]) async throws { writes += records.map(\.id) }
    func softDeleteSprayRecord(id: UUID) async throws { deletes.append(id) }
}

@MainActor private final class LegacyTripSyncProbe: TripSyncRepositoryProtocol {
    var writes: [UUID] = []; var deletes: [UUID] = []
    func fetchTrips(vineyardId: UUID, since: Date?) async throws -> [BackendTrip] { [] }
    func fetchAllTrips(vineyardId: UUID) async throws -> [BackendTrip] { [] }
    func fetchAllAccessibleTrips() async throws -> [BackendTrip] { [] }
    func upsertTrip(_ trip: BackendTripUpsert) async throws { writes.append(trip.id) }
    func upsertTrips(_ trips: [BackendTripUpsert]) async throws { writes += trips.map(\.id) }
    func updateTripVineyardAssignment(id: UUID, vineyardId: UUID, paddockId: UUID?) async throws { writes.append(id) }
    func updateTripWorkTaskLink(id: UUID, workTaskId: UUID?) async throws { writes.append(id) }
    func softDeleteTrip(id: UUID) async throws { deletes.append(id) }
}
