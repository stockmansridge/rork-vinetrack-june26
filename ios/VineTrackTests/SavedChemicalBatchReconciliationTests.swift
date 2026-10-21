import Foundation
import Testing
@testable import VineTrack

/// Exercises the production sync service, merge and persistence path. Counts
/// are collected after fixture setup; they describe actual codec/save calls,
/// not a timing claim about a simulator or handset.
@MainActor
struct SavedChemicalBatchReconciliationTests {
    @Test func unchangedFullSyncRetainsOrderAndDoesNotEncodeCollections() async throws {
        let vineyard = UUID()
        let rows = try (0..<100).map { try row(UUID(), vineyard: vineyard, name: "Product \($0)") }
        let harness = try SavedChemicalBatchHarness(vineyard: vineyard, rows: rows)
        defer { harness.cleanup() }
        let original = harness.store.savedChemicals
        let bytes = try Data(contentsOf: harness.chemicalFile)
        // A server result may arrive in another order without changing data.
        harness.repository.rows.reverse()
        harness.capture()

        await harness.service.sync(vineyardId: vineyard)

        #expect(harness.service.syncStatus == .success)
        #expect(harness.repository.sinceValues.count == 2)
        #expect(harness.repository.sinceValues.allSatisfy { $0 == nil })
        #expect(harness.chemicalSaves.isEmpty)
        #expect(harness.store.savedChemicals == original)
        #expect(try Data(contentsOf: harness.chemicalFile) == bytes)
        // The full-sync timestamp is still persisted once. Per-row no-op
        // acknowledgements must not produce a metadata save for every product.
        #expect(harness.metadataSaves.count == 1)
        #expect(harness.repository.inserted.isEmpty && harness.repository.updated.isEmpty)
    }

    @Test func sparseChangeCommitsOnceAndPreservesOtherVineyard() async throws {
        let vineyard = UUID(), otherVineyard = UUID()
        let rows = try (0..<40).map { try row(UUID(), vineyard: vineyard, name: "Product \($0)") }
        let otherRows = [SavedChemical(vineyardId: otherVineyard, name: "Other vineyard", ratePerHa: 0.12345678912345678)]
        let harness = try SavedChemicalBatchHarness(vineyard: vineyard, rows: rows, otherRows: otherRows)
        defer { harness.cleanup() }
        let originalIds = harness.store.savedChemicals.map(\.id)
        let changed = try row(rows[17].id, vineyard: vineyard, name: "Updated product", notes: "New label reference")
        harness.repository.rows[17] = changed
        harness.repository.rows.reverse()
        harness.capture()

        await harness.service.sync(vineyardId: vineyard)

        #expect(harness.service.syncStatus == .success)
        #expect(harness.chemicalSaves.count == 1)
        #expect(harness.chemicalSaves.first?.operation == .durableSave)
        #expect(harness.chemicalSaves.first?.succeeded == true)
        #expect(harness.store.savedChemicals.map(\.id) == originalIds)
        #expect(harness.store.savedChemicals.first { $0.id == changed.id } == changed.toSavedChemical())
        let restarted = PersistenceStore(directory: harness.directory)
        let all: [SavedChemical] = try #require(restarted.load(key: SprayRepository.savedChemicalsKey))
        #expect(all.filter { $0.vineyardId == otherVineyard } == otherRows)
        #expect(all.filter { $0.vineyardId == vineyard } == harness.store.savedChemicals)
        #expect(harness.repository.sinceValues.count == 2)
    }

    @Test func batchPreservesPendingIntentAndRetiresServerDeletedRows() async throws {
        let vineyard = UUID()
        let editedRow = try row(UUID(), vineyard: vineyard, name: "Old server name")
        let deleteRow = try row(UUID(), vineyard: vineyard, name: "Pending delete")
        let tombstone = try row(UUID(), vineyard: vineyard, name: "Server archived", archived: true)
        let missing = SavedChemical(vineyardId: vineyard, name: "Retained historical data", ratePerHa: 1.23456789)
        var beforeTombstone = tombstone.toSavedChemical()
        beforeTombstone.isActive = true
        let harness = try SavedChemicalBatchHarness(
            vineyard: vineyard,
            rows: [editedRow, deleteRow, tombstone],
            localRows: [editedRow.toSavedChemical(), deleteRow.toSavedChemical(), beforeTombstone, missing]
        )
        defer { harness.cleanup() }
        var edited = editedRow.toSavedChemical()
        edited.name = "Latest local edit"
        harness.store.updateSavedChemical(edited)
        let expectedEdited = try #require(harness.store.savedChemicals.first { $0.id == edited.id })
        harness.store.deleteSavedChemical(deleteRow.toSavedChemical())
        let created = SavedChemical(vineyardId: vineyard, name: "Offline create", ratePerHa: 0.987654321)
        harness.store.addSavedChemical(created)
        harness.store.onSavedChemicalCreated?(tombstone.id)
        harness.capture()

        try await harness.service.reconcile(vineyardId: vineyard)

        #expect(harness.chemicalSaves.count == 1)
        #expect(harness.store.savedChemicals.first { $0.id == edited.id } == expectedEdited)
        #expect(harness.store.savedChemicals.first { $0.id == created.id } == created)
        #expect(harness.store.savedChemicals.allSatisfy { $0.id != deleteRow.id })
        #expect(harness.store.savedChemicals.first { $0.id == tombstone.id }?.isActive == false)
        #expect(harness.store.savedChemicals.first { $0.id == missing.id }?.name == missing.name)
        #expect(harness.store.savedChemicals.first { $0.id == missing.id }?.isActive == false)
        let metadata = harness.reloadedMetadata()
        #expect(Set(metadata.pendingUpserts.keys) == Set([edited.id, created.id]))
        #expect(Set(metadata.pendingDeletes.keys) == Set([deleteRow.id]))
        #expect(metadata.pendingCreates == Set([created.id]))
        #expect(harness.repository.inserted.isEmpty && harness.repository.updated.isEmpty)
    }

    @Test func touchedDuplicateIdentityIsCollapsedByOneCommit() async throws {
        let vineyard = UUID()
        let first = try row(UUID(), vineyard: vineyard, name: "Canonical")
        let second = try row(UUID(), vineyard: vineyard, name: "Unaffected")
        var duplicate = first.toSavedChemical()
        duplicate.name = "Stale duplicate"
        let harness = try SavedChemicalBatchHarness(
            vineyard: vineyard, rows: [first, second],
            localRows: [first.toSavedChemical(), second.toSavedChemical(), duplicate]
        )
        defer { harness.cleanup() }
        harness.capture()

        try await harness.service.reconcile(vineyardId: vineyard)

        #expect(harness.chemicalSaves.count == 1)
        #expect(harness.store.savedChemicals == [first.toSavedChemical(), second.toSavedChemical()])
        let persisted: [SavedChemical] = try #require(PersistenceStore(directory: harness.directory).load(key: SprayRepository.savedChemicalsKey))
        #expect(persisted == harness.store.savedChemicals)
    }

    @Test func failedDataCommitKeepsPendingEditsButRetiresObservedCreateEvidence() async throws {
        let vineyard = UUID()
        let remoteCreated = try row(UUID(), vineyard: vineyard, name: "Server accepted create", clientUpdatedAt: "2999-01-01T00:00:00Z")
        let remoteDeleted = try row(UUID(), vineyard: vineyard, name: "Server deleted", archived: true)
        var localCreated = remoteCreated.toSavedChemical()
        localCreated.name = "Original local data"
        var localDeleted = remoteDeleted.toSavedChemical()
        localDeleted.isActive = true
        let harness = try SavedChemicalBatchHarness(vineyard: vineyard, rows: [remoteCreated, remoteDeleted], localRows: [localCreated, localDeleted])
        defer { harness.cleanup() }
        harness.store.onSavedChemicalCreated?(localCreated.id)
        harness.store.onSavedChemicalDeleted?(localDeleted.id)
        let originalRows = harness.store.savedChemicals
        let originalBytes = try Data(contentsOf: harness.chemicalFile)
        harness.persistence.durableSaveFailureForTesting = { key in
            key == SprayRepository.savedChemicalsKey ? CocoaError(.fileWriteUnknown) : nil
        }

        await harness.service.sync(vineyardId: vineyard)

        if case .failure = harness.service.syncStatus {} else {
            Issue.record("A failed chemical commit must fail the sync")
        }
        #expect(harness.store.savedChemicals == originalRows)
        #expect(try Data(contentsOf: harness.chemicalFile) == originalBytes)
        let metadata = harness.reloadedMetadata()
        #expect(metadata.pendingUpserts[localCreated.id] != nil)
        #expect(metadata.pendingDeletes[localDeleted.id] != nil)
        #expect(metadata.lastSync(for: vineyard) == nil)
        // Observing an ID remotely is independent evidence that it is no
        // longer an unacknowledged CREATE. Keeping that marker could later
        // resurrect a hard-deleted server row.
        #expect(!metadata.pendingCreates.contains(localCreated.id))
        #expect(harness.repository.inserted.isEmpty && harness.repository.updated.isEmpty)

        harness.persistence.durableSaveFailureForTesting = nil
        harness.repository.rows = []
        await harness.service.sync(vineyardId: vineyard)
        #expect(harness.repository.inserted.isEmpty)
        #expect(harness.store.savedChemicals.first { $0.id == localCreated.id }?.isActive == false)
    }

    @Test func corruptCacheIsNotOverwrittenByACompleteRemoteRead() async throws {
        let vineyard = UUID()
        let remote = try row(UUID(), vineyard: vineyard, name: "Server")
        let harness = try SavedChemicalBatchHarness(vineyard: vineyard, rows: [remote])
        defer { harness.cleanup() }
        let originalRows = harness.store.savedChemicals
        let corrupt = Data("retained-corrupt-chemical-cache".utf8)
        try corrupt.write(to: harness.chemicalFile, options: .atomic)
        harness.capture()

        do {
            try await harness.service.reconcile(vineyardId: vineyard)
            Issue.record("Corrupt persisted chemicals must not be treated as an empty collection")
        } catch {}

        #expect(harness.chemicalSaves.isEmpty)
        #expect(harness.store.savedChemicals == originalRows)
        #expect(try Data(contentsOf: harness.chemicalFile) == corrupt)
        #expect(harness.repository.inserted.isEmpty)
    }

    @Test func editQueuedWhileFetchIsInFlightIsPreserved() async throws {
        let vineyard = UUID()
        let original = try row(UUID(), vineyard: vineyard, name: "Remote old value")
        let harness = try SavedChemicalBatchHarness(vineyard: vineyard, rows: [original])
        defer { harness.cleanup() }
        harness.repository.beforeFetchReturn = {
            var edited = harness.store.savedChemicals[0]
            edited.name = "Edit made during the fetch"
            harness.store.updateSavedChemical(edited)
        }

        try await harness.service.reconcile(vineyardId: vineyard)

        #expect(harness.store.savedChemicals.first?.name == "Edit made during the fetch")
        #expect(harness.service.pendingUpsertCount == 1)
        let persisted: [SavedChemical] = try #require(PersistenceStore(directory: harness.directory).load(key: SprayRepository.savedChemicalsKey))
        #expect(persisted.first?.name == "Edit made during the fetch")
    }

    @Test func previousVineyardResponseCannotReplaceCurrentlyVisibleChemicals() async throws {
        let vineyard = UUID(), otherVineyard = UUID()
        let original = try row(UUID(), vineyard: vineyard, name: "Old vineyard product")
        let changed = try row(original.id, vineyard: vineyard, name: "Refreshed old vineyard product")
        let otherRows = [SavedChemical(vineyardId: otherVineyard, name: "Currently visible")]
        let harness = try SavedChemicalBatchHarness(vineyard: vineyard, rows: [changed], localRows: [original.toSavedChemical()], otherRows: otherRows)
        defer { harness.cleanup() }
        harness.repository.beforeFetchReturn = {
            harness.store.selectedVineyardId = otherVineyard
            harness.store.savedChemicals = otherRows
        }

        do { try await harness.service.reconcile(vineyardId: vineyard) }
        catch is CancellationError { /* Discarding an obsolete scope is also safe. */ }

        #expect(harness.store.selectedVineyardId == otherVineyard)
        #expect(harness.store.savedChemicals == otherRows)
        let persisted: [SavedChemical] = try #require(PersistenceStore(directory: harness.directory).load(key: SprayRepository.savedChemicalsKey))
        #expect(persisted.filter { $0.vineyardId == otherVineyard } == otherRows)
    }

    @Test func metadataNoopsDoNotSaveAndRealRemovalStillPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let key = "vinetrack_saved_chemical_sync_metadata"
        let dirty = UUID(), createOnly = UUID(), conflictOnly = UUID(), deleted = UUID(), untouched = UUID()
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        var state = ManagementSyncMetadata.State()
        state.pendingUpserts = [dirty: date, untouched: date]
        state.pendingCreates = [createOnly: date]
        state.pendingDeletes = [deleted: date]
        persistence.save(state, key: key)
        let metadata = ManagementSyncMetadata(key: key, persistence: persistence)
        metadata.markRevisionConflict(conflictOnly, baseRevision: 1, serverRevision: 2, at: date)
        var saves = 0
        persistence.onPersistenceMeasurementForTesting = {
            if $0.dataset == .chemicalMetadata && ($0.operation == .save || $0.operation == .durableSave) { saves += 1 }
        }

        metadata.clearDirty([])
        metadata.clearDeleted([])
        metadata.clearDirty([UUID()])
        metadata.clearDeleted([UUID()])
        #expect(saves == 0)
        metadata.clearDirty([dirty, createOnly, conflictOnly])
        #expect(saves == 1)
        metadata.clearDirty([dirty, createOnly, conflictOnly])
        #expect(saves == 1)
        metadata.clearDeleted([deleted])
        #expect(saves == 2)
        metadata.clearDeleted([deleted])
        #expect(saves == 2)

        let restored = ManagementSyncMetadata(key: key, persistence: PersistenceStore(directory: directory))
        #expect(Set(restored.pendingUpserts.keys) == Set([untouched]))
        #expect(restored.pendingCreates.isEmpty && restored.pendingDeletes.isEmpty)
        #expect(restored.conflictedIds.isEmpty)
    }

    @Test func batchAcknowledgementsPersistOnceAndRetainUnrelatedMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let key = "vinetrack_saved_chemical_sync_metadata"
        let first = UUID(), second = UUID(), deleted = UUID(), retained = UUID(), vineyard = UUID()
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        var state = ManagementSyncMetadata.State()
        state.pendingUpserts = [first: date, second: date, retained: date]
        state.pendingCreates = [first: date, second: date]
        state.pendingDeletes = [deleted: date]
        state.lastSyncByVineyard = [vineyard: date]
        state.observedRevisions = [first: 7]
        persistence.save(state, key: key)
        let metadata = ManagementSyncMetadata(key: key, persistence: persistence)
        var saves = 0
        persistence.onPersistenceMeasurementForTesting = {
            if $0.dataset == .chemicalMetadata && ($0.operation == .save || $0.operation == .durableSave) { saves += 1 }
        }

        metadata.acknowledgeCreates([])
        metadata.acknowledgeCreates([UUID()])
        #expect(saves == 0)
        metadata.acknowledgeCreates([first, second, first])
        #expect(saves == 1)
        #expect(metadata.pendingCreates.isEmpty)
        #expect(Set(metadata.pendingUpserts.keys) == Set([first, second, retained]))
        #expect(Set(metadata.pendingDeletes.keys) == Set([deleted]))
        metadata.acknowledgeCreates([first, second])
        #expect(saves == 1)

        metadata.clearAcknowledged(upserts: [first, second], deletes: [deleted])
        #expect(saves == 2)
        metadata.clearAcknowledged(upserts: [first, second], deletes: [deleted])
        metadata.clearAcknowledged(upserts: [], deletes: [])
        #expect(saves == 2)
        let restored = ManagementSyncMetadata(key: key, persistence: PersistenceStore(directory: directory))
        #expect(Set(restored.pendingUpserts.keys) == Set([retained]))
        #expect(restored.pendingCreates.isEmpty && restored.pendingDeletes.isEmpty)
        #expect(restored.lastSync(for: vineyard) == date)
        #expect(restored.observedRevision(for: first) == 7)
    }

    @Test func failedMetadataSaveIsRetriedByAnOtherwiseNoopAcknowledgement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let key = "vinetrack_saved_chemical_sync_metadata"
        let id = UUID()
        let metadata = ManagementSyncMetadata(key: key, persistence: persistence)
        metadata.markDirty(id, at: Date(timeIntervalSince1970: 1_760_000_000))
        var successfulSaves = 0
        persistence.onPersistenceMeasurementForTesting = {
            if $0.dataset == .chemicalMetadata && $0.operation == .durableSave && $0.succeeded { successfulSaves += 1 }
        }
        persistence.durableSaveFailureForTesting = { failingKey in
            failingKey == key ? CocoaError(.fileWriteUnknown) : nil
        }

        metadata.clearDirty([id])

        // The existing metadata contract mutates memory before saving. A
        // subsequent no-op must still retry this failed persistence attempt.
        #expect(metadata.pendingUpserts[id] == nil)
        #expect(ManagementSyncMetadata(key: key, persistence: PersistenceStore(directory: directory)).pendingUpserts[id] != nil)
        #expect(successfulSaves == 0)
        persistence.durableSaveFailureForTesting = nil
        metadata.clearDirty([id])
        #expect(successfulSaves == 1)
        #expect(ManagementSyncMetadata(key: key, persistence: PersistenceStore(directory: directory)).pendingUpserts[id] == nil)
        metadata.clearDirty([id])
        #expect(successfulSaves == 1)
    }

    private func row(_ id: UUID, vineyard: UUID, name: String, notes: String = "", archived: Bool = false, clientUpdatedAt: String = "2026-01-01T00:00:00Z") throws -> BackendSavedChemical {
        var object: [String: Any] = [
            "id": id.uuidString, "vineyard_id": vineyard.uuidString,
            "name": name, "notes": notes, "is_active": true,
            "rate_per_ha": 0.12345678912345678,
            "client_updated_at": clientUpdatedAt
        ]
        if archived { object["deleted_at"] = "2026-10-01T00:00:00Z" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackendSavedChemical.self, from: JSONSerialization.data(withJSONObject: object, options: .sortedKeys))
    }
}

@MainActor
private final class SavedChemicalBatchHarness {
    let directory: URL
    let persistence: PersistenceStore
    let store: MigratedDataStore
    let auth: NewBackendAuthService
    let repository: BatchChemicalRepository
    let service: SavedChemicalSyncService
    var measurements: [PersistenceMeasurement] = []

    var chemicalFile: URL { directory.appendingPathComponent("\(SprayRepository.savedChemicalsKey).json") }
    var chemicalSaves: [PersistenceMeasurement] {
        measurements.filter { $0.dataset == .chemicals && ($0.operation == .save || $0.operation == .durableSave) }
    }
    var metadataSaves: [PersistenceMeasurement] {
        measurements.filter { $0.dataset == .chemicalMetadata && ($0.operation == .save || $0.operation == .durableSave) }
    }

    init(vineyard: UUID, rows: [BackendSavedChemical], localRows: [SavedChemical]? = nil, otherRows: [SavedChemical] = []) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyard
        let auth = NewBackendAuthService()
        let repository = BatchChemicalRepository(rows: rows)
        let service = SavedChemicalSyncService(repository: repository, persistence: persistence, backendConfigured: { true })
        self.directory = directory
        self.persistence = persistence
        self.store = store
        self.auth = auth
        self.repository = repository
        self.service = service
        service.configure(store: store, auth: auth)
        let local = localRows ?? rows.map { $0.toSavedChemical() }
        try persistence.saveOrThrow(otherRows + local, key: SprayRepository.savedChemicalsKey)
        store.savedChemicals = local
    }

    func capture() {
        measurements = []
        persistence.onPersistenceMeasurementForTesting = { [weak self] in self?.measurements.append($0) }
    }

    func reloadedMetadata() -> ManagementSyncMetadata {
        ManagementSyncMetadata(key: "vinetrack_saved_chemical_sync_metadata", persistence: PersistenceStore(directory: directory))
    }

    func cleanup() {
        repository.beforeFetchReturn = nil
        persistence.onPersistenceMeasurementForTesting = nil
        persistence.durableSaveFailureForTesting = nil
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class BatchChemicalRepository: SavedChemicalSyncRepositoryProtocol {
    var rows: [BackendSavedChemical]
    var sinceValues: [Date?] = []
    var inserted: [UUID] = []
    var updated: [UUID] = []
    var beforeFetchReturn: (() -> Void)?

    init(rows: [BackendSavedChemical]) { self.rows = rows }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendSavedChemical] {
        sinceValues.append(since)
        let response = rows.filter { $0.vineyardId == vineyardId }
        let action = beforeFetchReturn
        beforeFetchReturn = nil
        action?()
        return response
    }

    func upsertMany(_ items: [BackendSavedChemicalUpsert]) async throws { inserted.append(contentsOf: items.map(\.id)) }
    func updateExisting(_ item: BackendSavedChemicalUpsert) async throws { updated.append(item.id) }
    func softDelete(id: UUID) async throws {}
    func softDeleteRPC(id: UUID) async throws -> SoftDeleteSavedChemicalResult {
        SoftDeleteSavedChemicalResult(ok: false, reason: "not_found", archived: nil, alreadyArchived: nil)
    }
    func hardDeleteUnused(id: UUID) async throws -> HardDeleteSavedChemicalResult {
        HardDeleteSavedChemicalResult(ok: false, deleted: nil, reason: "not_found", message: nil)
    }
}
