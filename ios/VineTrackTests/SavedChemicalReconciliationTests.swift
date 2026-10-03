import Foundation
import Testing
@testable import VineTrack

@MainActor
struct SavedChemicalReconciliationTests {
    @Test func completeReadRepairsStaleCacheWithoutSeedingAndSurvivesRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let vineyard = UUID()
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyard
        let activeIds = Set((0..<12).map { _ in UUID() })
        let archivedId = UUID(), missingId = UUID()
        let remote = try activeIds.map { try row($0, vineyard: vineyard) } + [row(archivedId, vineyard: vineyard, archived: true)]
        let repository = ChemicalReconciliationRepository(rows: remote)
        let auth = NewBackendAuthService()
        let service = SavedChemicalSyncService(repository: repository, persistence: persistence, backendConfigured: { true })
        service.configure(store: store, auth: auth)
        // An old generic dirty EDIT is not an offline CREATE, even with a newer clock.
        let stale = SavedChemical(id: missingId, vineyardId: vineyard, name: "Retained historical value", ratePerHa: 2)
        store.sprayRepo.replaceChemicals(remote.map { var c = $0.toSavedChemical(); c.isActive = true; return c } + [stale], for: vineyard)
        store.savedChemicals = store.sprayRepo.loadChemicals(for: vineyard)
        store.onSavedChemicalChanged?(missingId)
        await service.sync(vineyardId: vineyard)
        #expect(service.syncStatus == .success)
        #expect(Set(ChemicalStorePresentation.active(store.savedChemicals).map(\.id)) == activeIds)
        #expect(store.savedChemicals.first { $0.id == archivedId }?.isActive == false)
        #expect(store.savedChemicals.first { $0.id == missingId }?.name == stale.name)
        #expect(repository.inserted.isEmpty && repository.updated.isEmpty)
        #expect(repository.sinceValues.allSatisfy { $0 == nil })
        let restarted = MigratedDataStore(persistence: persistence)
        restarted.selectedVineyardId = vineyard
        restarted.savedChemicals = restarted.sprayRepo.loadChemicals(for: vineyard)
        let resumed = SavedChemicalSyncService(repository: repository, persistence: persistence, backendConfigured: { true })
        resumed.configure(store: restarted, auth: auth)
        await resumed.sync(vineyardId: vineyard)
        #expect(Set(ChemicalStorePresentation.active(restarted.savedChemicals).map(\.id)) == activeIds)
        #expect(repository.inserted.isEmpty)
    }

    @Test func realOfflineCreateSurvivesReconciliationAndUploadsSameId() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let vineyard = UUID()
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyard
        let repository = ChemicalReconciliationRepository(rows: [])
        let auth = NewBackendAuthService()
        let first = SavedChemicalSyncService(repository: repository, persistence: persistence, backendConfigured: { true })
        first.configure(store: store, auth: auth)
        let created = SavedChemical(vineyardId: vineyard, name: "Offline create", ratePerHa: 2)
        store.addSavedChemical(created)
        let resumed = SavedChemicalSyncService(repository: repository, persistence: persistence, backendConfigured: { true })
        resumed.configure(store: store, auth: auth)
        try await resumed.reconcile(vineyardId: vineyard)
        #expect(ChemicalStorePresentation.active(store.savedChemicals).map(\.id) == [created.id])
        await resumed.sync(vineyardId: vineyard)
        #expect(repository.inserted == [created.id])
        #expect(resumed.pendingUpsertCount == 0)
        #expect(ChemicalStorePresentation.active(store.savedChemicals).map(\.id) == [created.id])
        // Once observed remotely, even an old CREATE marker must not resurrect a later hard delete.
        repository.rows = []
        await resumed.sync(vineyardId: vineyard)
        #expect(ChemicalStorePresentation.active(store.savedChemicals).isEmpty)
        #expect(repository.inserted == [created.id])
    }

    @Test func failedCompleteReadCannotArchiveCacheOrReplayWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let vineyard = UUID(), auth = NewBackendAuthService()
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyard
        let repository = ChemicalReconciliationRepository(rows: [])
        repository.failsFetch = true
        let service = SavedChemicalSyncService(repository: repository, persistence: persistence, backendConfigured: { true })
        service.configure(store: store, auth: auth)
        let created = SavedChemical(vineyardId: vineyard, name: "Offline")
        store.addSavedChemical(created)
        await service.sync(vineyardId: vineyard)
        #expect(store.savedChemicals == [created])
        #expect(repository.inserted.isEmpty)
        #expect(service.pendingUpsertCount == 1)
    }

    @Test(arguments: [false, true])
    func notFoundDeletionRetiresSafelyAndRetainsOnlyReferencedHistory(historical: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let vineyard = UUID()
        store.selectedVineyardId = vineyard
        let chemical = SavedChemical(vineyardId: vineyard, name: "Stale local only")
        store.addSavedChemical(chemical)
        if historical {
            store.sprayRepo.saveRecordsSlice([SprayRecord(vineyardId: vineyard, tanks: [SprayTank(chemicals: [SprayChemical(name: chemical.name, savedChemicalId: chemical.id)])])], for: vineyard)
        }
        let coordinator = ChemicalDeleteCoordinator(service: SavedChemicalDeletionService(repository: ChemicalReconciliationRepository(rows: [])))
        coordinator.pending = chemical
        await coordinator.hardDelete(chemical, store: store)
        #expect(coordinator.pending == nil)
        #expect(coordinator.didDeleteId == chemical.id)
        #expect(coordinator.alertMessage == nil && !coordinator.isWorking)
        #expect(ChemicalStorePresentation.active(store.savedChemicals).isEmpty)
        #expect(store.sprayRepo.loadChemicals(for: vineyard).count == (historical ? 1 : 0))
        if historical { #expect(store.savedChemicals.first?.name == chemical.name) }
    }

    @Test func tombstoneCancelsPendingCreateAndDuplicateCacheRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let vineyard = UUID(), auth = NewBackendAuthService()
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyard
        let created = SavedChemical(vineyardId: vineyard, name: "Unacknowledged create")
        let repository = ChemicalReconciliationRepository(rows: [try row(created.id, vineyard: vineyard, archived: true)])
        let service = SavedChemicalSyncService(repository: repository, persistence: persistence, backendConfigured: { true })
        service.configure(store: store, auth: auth)
        store.addSavedChemical(created)
        store.savedChemicals.append(created)
        store.sprayRepo.saveChemicalsSlice(store.savedChemicals, for: vineyard)
        await service.sync(vineyardId: vineyard)
        #expect(ChemicalStorePresentation.active(store.savedChemicals).isEmpty)
        #expect(store.savedChemicals.count == 1)
        #expect(repository.inserted.isEmpty)
        #expect(service.pendingUpsertCount == 0)
    }

    @Test func duplicateCachedIdentityCannotTrapAssessment() {
        let chemical = SavedChemical(name: "Cached duplicate")
        #expect(ChemicalStorePresentation.active([chemical, chemical]).count == 1)
        #expect(ChemicalStoreAssessment.activeAssessments([chemical, chemical], resolutions: [:]).count == 1)
    }

    private func row(_ id: UUID, vineyard: UUID, archived: Bool = false) throws -> BackendSavedChemical {
        let deleted = archived ? ",\"deleted_at\":\"2026-10-02T00:00:00Z\"" : ""
        let data = Data("{\"id\":\"\(id)\",\"vineyard_id\":\"\(vineyard)\",\"name\":\"Server product\",\"is_active\":true\(deleted)}".utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackendSavedChemical.self, from: data)
    }
}

@MainActor
private final class ChemicalReconciliationRepository: SavedChemicalSyncRepositoryProtocol {
    var rows: [BackendSavedChemical]
    var inserted: [UUID] = []
    var updated: [UUID] = []
    var sinceValues: [Date?] = []
    var failsFetch: Bool = false
    init(rows: [BackendSavedChemical]) { self.rows = rows }
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendSavedChemical] {
        sinceValues.append(since)
        if failsFetch { throw URLError(.notConnectedToInternet) }
        return rows.filter { $0.vineyardId == vineyardId }
    }
    func upsertMany(_ items: [BackendSavedChemicalUpsert]) async throws {
        for item in items {
            inserted.append(item.id)
            let data = Data("{\"id\":\"\(item.id)\",\"vineyard_id\":\"\(item.vineyardId)\",\"name\":\"Uploaded\",\"is_active\":true}".utf8)
            rows.append(try JSONDecoder().decode(BackendSavedChemical.self, from: data))
        }
    }
    func updateExisting(_ item: BackendSavedChemicalUpsert) async throws { updated.append(item.id) }
    func softDelete(id: UUID) async throws {}
    func softDeleteRPC(id: UUID) async throws -> SoftDeleteSavedChemicalResult {
        SoftDeleteSavedChemicalResult(ok: false, reason: "not_found", archived: nil, alreadyArchived: nil)
    }
    func hardDeleteUnused(id: UUID) async throws -> HardDeleteSavedChemicalResult {
        HardDeleteSavedChemicalResult(ok: false, deleted: nil, reason: "not_found", message: nil)
    }
}
