import Foundation

protocol SavedChemicalSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendSavedChemical]
    func upsertMany(_ items: [BackendSavedChemicalUpsert]) async throws
    func softDelete(id: UUID) async throws
    /// Calls the `soft_delete_saved_chemicals` RPC and returns the structured result.
    func softDeleteRPC(id: UUID) async throws -> SoftDeleteSavedChemicalResult
    /// Calls the `hard_delete_unused_saved_chemical` RPC. Backend rejects when the
    /// chemical has been used in any operational/historical record.
    func hardDeleteUnused(id: UUID) async throws -> HardDeleteSavedChemicalResult
}

nonisolated struct SoftDeleteSavedChemicalResult: Decodable, Sendable {
    let ok: Bool
    let reason: String?
    let archived: Bool?
    let alreadyArchived: Bool?

    enum CodingKeys: String, CodingKey {
        case ok, reason, archived
        case alreadyArchived = "already_archived"
    }
}

nonisolated struct HardDeleteSavedChemicalResult: Decodable, Sendable {
    let ok: Bool
    let deleted: Bool?
    let reason: String?
    let message: String?
}

protocol SavedSprayPresetSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendSavedSprayPreset]
    func upsertMany(_ items: [BackendSavedSprayPresetUpsert]) async throws
    func softDelete(id: UUID) async throws
}

protocol SprayEquipmentSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendSprayEquipment]
    func upsertMany(_ items: [BackendSprayEquipmentUpsert]) async throws
    func softDelete(id: UUID) async throws
}

protocol TractorSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendTractor]
    func upsertMany(_ items: [BackendTractorUpsert]) async throws
    func softDelete(id: UUID) async throws
}

protocol VineyardMachineSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendVineyardMachine]
    func upsertMany(_ items: [BackendVineyardMachineUpsert]) async throws
    func softDelete(id: UUID) async throws
}

protocol FuelPurchaseSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendFuelPurchase]
    func upsertMany(_ items: [BackendFuelPurchaseUpsert]) async throws
    func softDelete(id: UUID) async throws
}

protocol TractorFuelLogSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendTractorFuelLog]
    func upsertMany(_ items: [BackendTractorFuelLogUpsert]) async throws
    func softDelete(id: UUID) async throws
}

protocol OperatorCategorySyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendOperatorCategory]
    func upsertMany(_ items: [BackendOperatorCategoryUpsert]) async throws
    func softDelete(id: UUID) async throws
}

protocol WorkTaskTypeSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendWorkTaskType]
    func upsertMany(_ items: [BackendWorkTaskTypeUpsert]) async throws
    func softDelete(id: UUID) async throws
}

protocol EquipmentItemSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendEquipmentItem]
    func upsertMany(_ items: [BackendEquipmentItemUpsert]) async throws
    func softDelete(id: UUID) async throws
}

protocol SavedInputSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendSavedInput]
    func upsertMany(_ items: [BackendSavedInputUpsert]) async throws
    func softDelete(id: UUID) async throws
}
