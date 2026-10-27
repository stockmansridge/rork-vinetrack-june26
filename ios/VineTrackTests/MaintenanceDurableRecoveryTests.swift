import Foundation
import Testing
@testable import VineTrack

@MainActor
struct MaintenanceDurableRecoveryTests {
    @Test func foregroundSaveAndDeleteRecoverWithoutAnySyncCallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        let user = UUID(), vineyard = UUID()
        let gate = VineyardWriteAuthority(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        gate.bind(userId: user)
        store.operationalWriteAuthority = gate
        store.currentUserIdProvider = { user }
        store.selectedVineyardId = vineyard
        let record = MaintenanceLog(vineyardId: vineyard, itemName: "Synthetic pump", invoicePhotoData: Data([1, 2, 3]))
        #expect(store.addMaintenanceLog(record))
        let restored = MaintenanceLogRepository(persistence: PersistenceStore(directory: directory))
        let create = try #require(restored.pendingIntents()[record.id])
        #expect(create.accountId == user && create.original.invoicePhotoData == Data([1, 2, 3]))
        #expect(!create.deleted && restored.loadAll().count == 1)
        var edited = record
        edited.itemName = "Synthetic pump serviced"
        #expect(store.updateMaintenanceLog(edited))
        let update = try #require(restored.pendingIntents()[record.id])
        #expect(update.token != create.token && update.original.itemName == edited.itemName)
        try restored.acknowledge([record.id: create.token])
        #expect(restored.pendingIntents()[record.id]?.token == update.token)
        #expect(store.deleteMaintenanceLog(record.id))
        let deletion = try #require(restored.pendingIntents()[record.id])
        #expect(deletion.deleted && deletion.original.invoicePhotoData == Data([1, 2, 3]))
        #expect(restored.loadAll().isEmpty)
        try restored.acknowledge([record.id: update.token])
        #expect(restored.pendingIntents()[record.id]?.token == deletion.token)
        restored.replace([record], for: vineyard)
        #expect(restored.loadAll().isEmpty)
        try restored.acknowledge([record.id: deletion.token])
        #expect(restored.pendingIntents().isEmpty && restored.loadAll().isEmpty)
    }

    @Test func failedEditAndDeleteLeaveOriginalEnvelopeAndMemoryIntact() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let user = UUID(), vineyard = UUID()
        let gate = VineyardWriteAuthority(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        gate.bind(userId: user)
        store.operationalWriteAuthority = gate
        store.currentUserIdProvider = { user }
        store.selectedVineyardId = vineyard
        let record = MaintenanceLog(vineyardId: vineyard, itemName: "Original")
        #expect(store.addMaintenanceLog(record))
        let file = directory.appendingPathComponent(MaintenanceLogRepository.storageKey + ".json")
        let before = try Data(contentsOf: file)
        persistence.durableSaveFailureForTesting = { _ in CocoaError(.fileWriteUnknown) }
        var edited = record
        edited.itemName = "Must not publish"
        #expect(!store.updateMaintenanceLog(edited))
        #expect(!store.deleteMaintenanceLog(record.id))
        #expect(try Data(contentsOf: file) == before)
        #expect(store.maintenanceLogs.first?.itemName == "Original")
    }

    @Test func legacyArrayMigratesWithoutInventingIntentAndRetainsOtherVineyard() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let a = MaintenanceLog(vineyardId: UUID(), itemName: "A")
        let b = MaintenanceLog(vineyardId: UUID(), itemName: "B")
        try persistence.saveOrThrow([a, b], key: MaintenanceLogRepository.storageKey)
        let repo = MaintenanceLogRepository(persistence: persistence)
        #expect(repo.pendingIntents().isEmpty && repo.loadAll().count == 2)
        try repo.saveLocal(a, accountId: UUID())
        repo.replace([], for: b.vineyardId)
        #expect(repo.loadAll().map(\.id) == [a.id])
        #expect(repo.pendingIntents()[a.id] != nil)
    }

    @Test func uploadReceiptSurvivesRestartAndNeverReplacesNewerRevision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = MaintenanceLogRepository(persistence: PersistenceStore(directory: directory))
        let user = UUID()
        var record = MaintenanceLog(vineyardId: UUID(), itemName: "Original", invoicePhotoData: Data([7, 8]))
        try repo.saveLocal(record, accountId: user)
        let original = try #require(repo.pendingIntents()[record.id])
        let path = MaintenancePhotoStorage.path(vineyardId: record.vineyardId, maintenanceId: record.id)
        #expect(try repo.retainPhotoReceipt(id: record.id, token: original.token, path: path))
        let restored = MaintenanceLogRepository(persistence: PersistenceStore(directory: directory))
        #expect(restored.pendingIntents()[record.id]?.original.photoPath == path)
        #expect(restored.pendingIntents()[record.id]?.original.invoicePhotoData == Data([7, 8]))
        record.itemName = "Newer"
        try repo.saveLocal(record, accountId: user, at: original.timestamp)
        #expect(try !restored.retainPhotoReceipt(id: record.id, token: original.token, path: path))
        try restored.acknowledge([record.id: original.token])
        #expect(restored.pendingIntents()[record.id]?.original.itemName == "Newer")
        #expect(restored.loadAll().first?.photoPath == nil)
    }

    @Test func anotherAccountCannotReplacePendingOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = MaintenanceLogRepository(persistence: PersistenceStore(directory: directory))
        let user = UUID(), other = UUID()
        let record = MaintenanceLog(vineyardId: UUID(), itemName: "Original")
        try repo.saveLocal(record, accountId: user)
        #expect(throws: (any Error).self) { try repo.saveLocal(record, accountId: other, deleted: true) }
        #expect(repo.pendingIntents()[record.id]?.accountId == user)
        #expect(repo.loadAll().first?.itemName == "Original")
    }

    @Test func failedAcknowledgementRetainsExactReplayIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let repo = MaintenanceLogRepository(persistence: persistence)
        let record = MaintenanceLog(vineyardId: UUID(), itemName: "Original")
        try repo.saveLocal(record, accountId: UUID(), deleted: true)
        let intent = try #require(repo.pendingIntents()[record.id])
        persistence.durableSaveFailureForTesting = { _ in CocoaError(.fileWriteUnknown) }
        #expect(throws: (any Error).self) { try repo.acknowledge([record.id: intent.token]) }
        let restored = MaintenanceLogRepository(persistence: PersistenceStore(directory: directory))
        #expect(restored.pendingIntents()[record.id]?.token == intent.token)
        #expect(restored.pendingIntents()[record.id]?.timestamp == intent.timestamp)
        #expect(restored.loadAll().isEmpty)
    }
}
