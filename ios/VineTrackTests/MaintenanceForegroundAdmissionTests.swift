import Foundation
import Testing
@testable import VineTrack

@MainActor
struct MaintenanceForegroundAdmissionTests {
    @Test func heldOriginalCannotBorrowSelectedVineyardForCreateEditOrDelete() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let user = UUID(), a = UUID(), b = UUID()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let gate = VineyardWriteAuthority(defaults: defaults)
        gate.bind(userId: user)
        store.operationalWriteAuthority = gate
        store.currentUserIdProvider = { user }
        let original = MaintenanceLog(vineyardId: a, itemName: "Original", date: Date(timeIntervalSince1970: 12345), invoicePhotoData: Data([1, 2]), photoPath: "original-photo", createdBy: "Original author")
        store.maintenanceLogRepo.saveSlice([original], for: a)
        store.selectedVineyardId = b
        // A stale sheet/slice must not acquire B's permission, even before the next pull.
        store.maintenanceLogs = [original]
        gate.hold(vineyardId: a.uuidString, reason: "VT_READ_ONLY")
        var changed = 0, deleted = 0
        store.onMaintenanceLogChanged = { _ in changed += 1 }
        store.onMaintenanceLogDeleted = { _ in deleted += 1 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(store.maintenanceLogRepo.loadAll())
        var edit = original
        edit.itemName = "Must not replace original"
        store.updateMaintenanceLog(edit)
        store.deleteMaintenanceLog(original.id)
        store.addMaintenanceLog(MaintenanceLog(vineyardId: a, itemName: "Must not move to B"))
        #expect(try encoder.encode(store.maintenanceLogRepo.loadAll()) == before)
        #expect(store.maintenanceLogs.count == 1 && store.maintenanceLogs.first?.itemName == "Original")
        #expect(changed == 0 && deleted == 0)
    }

    @Test func editorRetainsOriginalDraftAcrossHoldAndRejectsSameAccountReturn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        let user = UUID(), vineyard = UUID(), other = UUID()
        let gate = VineyardWriteAuthority(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        gate.bind(userId: user)
        store.operationalWriteAuthority = gate
        store.currentUserIdProvider = { user }
        store.selectedVineyardId = vineyard
        let scope = try #require(store.captureMaintenanceEditScope(vineyardId: vineyard))
        let original = MaintenanceLog(vineyardId: vineyard, itemName: "Original", invoicePhotoData: Data([4, 5]), createdBy: "Original author")
        #expect(store.addMaintenanceLog(original, scope: scope))
        var changes = 0
        store.onMaintenanceLogChanged = { _ in changes += 1 }
        var draft = original
        draft.itemName = "Original explicit edit"
        draft.createdBy = "Must not replace author"
        gate.hold(vineyardId: vineyard.uuidString, reason: "VT_READ_ONLY")
        #expect(!store.updateMaintenanceLog(draft, scope: scope))
        gate.verified(vineyardId: other.uuidString, access: .init(legacyCanEnter: true, canWrite: true), explicitlyWritable: true)
        #expect(!store.updateMaintenanceLog(draft, scope: scope))
        #expect(changes == 0 && store.maintenanceLogRepo.loadAll().first?.itemName == "Original")
        gate.verified(vineyardId: vineyard.uuidString, access: .init(legacyCanEnter: true, canWrite: true), explicitlyWritable: true)
        #expect(store.updateMaintenanceLog(draft, scope: scope))
        #expect(changes == 1)
        #expect(store.maintenanceLogRepo.loadAll().first?.createdBy == "Original author")
        #expect(store.maintenanceLogRepo.loadAll().first?.invoicePhotoData == Data([4, 5]))
        gate.bind(userId: nil)
        gate.bind(userId: user)
        #expect(!store.updateMaintenanceLog(draft, scope: scope))
        #expect(!store.deleteMaintenanceLog(original.id, scope: scope))
        #expect(!store.addMaintenanceLog(MaintenanceLog(vineyardId: vineyard), scope: scope))
        #expect(changes == 1 && store.maintenanceLogRepo.loadAll().count == 1)
    }

    @Test func forgedVineyardCannotRetargetPersistedMaintenanceRow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        let user = UUID(), a = UUID(), b = UUID()
        let gate = VineyardWriteAuthority(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        gate.bind(userId: user)
        store.currentUserIdProvider = { user }
        store.operationalWriteAuthority = gate
        let original = MaintenanceLog(vineyardId: a, itemName: "A")
        store.maintenanceLogRepo.saveSlice([original], for: a)
        var forged = original
        forged.vineyardId = b
        store.selectedVineyardId = b
        store.maintenanceLogs = [forged]
        #expect(!store.updateMaintenanceLog(forged))
        #expect(!store.addMaintenanceLog(forged))
        #expect(store.maintenanceLogRepo.load(for: a).first?.itemName == "A")
        #expect(store.maintenanceLogRepo.load(for: b).isEmpty)
    }
}
