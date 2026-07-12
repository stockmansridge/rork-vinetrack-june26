import Foundation
import Supabase

private nonisolated struct SoftDeleteByIdRequest: Encodable, Sendable {
    let id: UUID
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
    }
}

private func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

// MARK: - Saved Chemicals

final class SupabaseSavedChemicalSyncRepository: SavedChemicalSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendSavedChemical] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("saved_chemicals").select().eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await q.gte("updated_at", value: iso(since)).order("updated_at", ascending: true).execute().value
        }
        return try await q.order("updated_at", ascending: true).execute().value
    }

    func upsertMany(_ items: [BackendSavedChemicalUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("saved_chemicals").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_saved_chemical", params: SoftDeleteByIdRequest(id: id)).execute()
    }

    func softDeleteRPC(id: UUID) async throws -> SoftDeleteSavedChemicalResult {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let result: SoftDeleteSavedChemicalResult = try await provider.client
            .rpc("soft_delete_saved_chemicals", params: SoftDeleteByIdRequest(id: id))
            .execute()
            .value
        return result
    }

    func hardDeleteUnused(id: UUID) async throws -> HardDeleteSavedChemicalResult {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let result: HardDeleteSavedChemicalResult = try await provider.client
            .rpc("hard_delete_unused_saved_chemical", params: SoftDeleteByIdRequest(id: id))
            .execute()
            .value
        return result
    }
}

// MARK: - Saved Spray Presets

final class SupabaseSavedSprayPresetSyncRepository: SavedSprayPresetSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendSavedSprayPreset] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("saved_spray_presets").select().eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await q.gte("updated_at", value: iso(since)).order("updated_at", ascending: true).execute().value
        }
        return try await q.order("updated_at", ascending: true).execute().value
    }

    func upsertMany(_ items: [BackendSavedSprayPresetUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("saved_spray_presets").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_saved_spray_preset", params: SoftDeleteByIdRequest(id: id)).execute()
    }
}

// MARK: - Spray Equipment

final class SupabaseSprayEquipmentSyncRepository: SprayEquipmentSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendSprayEquipment] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("spray_equipment").select().eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await q.gte("updated_at", value: iso(since)).order("updated_at", ascending: true).execute().value
        }
        return try await q.order("updated_at", ascending: true).execute().value
    }

    func upsertMany(_ items: [BackendSprayEquipmentUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("spray_equipment").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_spray_equipment", params: SoftDeleteByIdRequest(id: id)).execute()
    }
}

// MARK: - Tractors

final class SupabaseTractorSyncRepository: TractorSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendTractor] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("tractors").select().eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await q.gte("updated_at", value: iso(since)).order("updated_at", ascending: true).execute().value
        }
        return try await q.order("updated_at", ascending: true).execute().value
    }

    func upsertMany(_ items: [BackendTractorUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("tractors").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_tractor", params: SoftDeleteByIdRequest(id: id)).execute()
    }
}

// MARK: - Vineyard Machines

final class SupabaseVineyardMachineSyncRepository: VineyardMachineSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendVineyardMachine] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("vineyard_machines").select().eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await q.gte("updated_at", value: iso(since)).order("updated_at", ascending: true).execute().value
        }
        return try await q.order("updated_at", ascending: true).execute().value
    }

    func upsertMany(_ items: [BackendVineyardMachineUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("vineyard_machines").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_vineyard_machine", params: SoftDeleteByIdRequest(id: id)).execute()
    }
}

// MARK: - Fuel Purchases

final class SupabaseFuelPurchaseSyncRepository: FuelPurchaseSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendFuelPurchase] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("fuel_purchases").select().eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await q.gte("updated_at", value: iso(since)).order("updated_at", ascending: true).execute().value
        }
        return try await q.order("updated_at", ascending: true).execute().value
    }

    func upsertMany(_ items: [BackendFuelPurchaseUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("fuel_purchases").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_fuel_purchase", params: SoftDeleteByIdRequest(id: id)).execute()
    }
}

// MARK: - Tractor Fuel Logs

final class SupabaseTractorFuelLogSyncRepository: TractorFuelLogSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendTractorFuelLog] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("tractor_fuel_logs").select().eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await q.gte("updated_at", value: iso(since)).order("updated_at", ascending: true).execute().value
        }
        return try await q.order("updated_at", ascending: true).execute().value
    }

    func upsertMany(_ items: [BackendTractorFuelLogUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("tractor_fuel_logs").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_tractor_fuel_log", params: SoftDeleteByIdRequest(id: id)).execute()
    }
}

// MARK: - Operator Categories

final class SupabaseOperatorCategorySyncRepository: OperatorCategorySyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendOperatorCategory] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("worker_types").select().eq("vineyard_id", value: vineyardId.uuidString)
        let data: Data
        if let since {
            data = try await q.gte("updated_at", value: iso(since)).order("updated_at", ascending: true).execute().data
        } else {
            data = try await q.order("updated_at", ascending: true).execute().data
        }
        // Per-row resilient decode so a single bad row created in Lovable does
        // not hide the entire vineyard's operator categories from iOS.
        let decoder = JSONDecoder()
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            #if DEBUG
            print("[OperatorCategorySync] fetch: unexpected payload shape, falling back to typed decode")
            #endif
            if let since {
                return try await q.gte("updated_at", value: iso(since)).order("updated_at", ascending: true).execute().value
            }
            return try await q.order("updated_at", ascending: true).execute().value
        }
        var records: [BackendOperatorCategory] = []
        records.reserveCapacity(array.count)
        for row in array {
            let id = (row["id"] as? String) ?? "<unknown-id>"
            do {
                let rowData = try JSONSerialization.data(withJSONObject: row)
                let record = try decoder.decode(BackendOperatorCategory.self, from: rowData)
                records.append(record)
            } catch {
                #if DEBUG
                print("[OperatorCategorySync] decode failed id=\(id) error=\(error)")
                #endif
            }
        }
        #if DEBUG
        print("[OperatorCategorySync] fetched \(array.count) row(s), decoded \(records.count) for vineyard \(vineyardId.uuidString)")
        #endif
        return records
    }

    func upsertMany(_ items: [BackendOperatorCategoryUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("worker_types").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_worker_type", params: SoftDeleteByIdRequest(id: id)).execute()
    }
}

// MARK: - Work Task Types

final class SupabaseWorkTaskTypeSyncRepository: WorkTaskTypeSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendWorkTaskType] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("work_task_types").select().eq("vineyard_id", value: vineyardId.uuidString)
        let data: Data
        if let since {
            data = try await q.gte("updated_at", value: iso(since)).order("updated_at", ascending: true).execute().data
        } else {
            data = try await q.order("updated_at", ascending: true).execute().data
        }
        // Per-row resilient decode so a single bad catalog row created in
        // Lovable does not hide the entire vineyard's task types from iOS.
        let decoder = JSONDecoder()
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            #if DEBUG
            print("[WorkTaskTypeSync] fetch: unexpected payload shape, falling back to typed decode")
            #endif
            if let since {
                return try await q.gte("updated_at", value: iso(since)).order("updated_at", ascending: true).execute().value
            }
            return try await q.order("updated_at", ascending: true).execute().value
        }
        var records: [BackendWorkTaskType] = []
        records.reserveCapacity(array.count)
        for row in array {
            let id = (row["id"] as? String) ?? "<unknown-id>"
            do {
                let rowData = try JSONSerialization.data(withJSONObject: row)
                let record = try decoder.decode(BackendWorkTaskType.self, from: rowData)
                records.append(record)
            } catch {
                #if DEBUG
                print("[WorkTaskTypeSync] decode failed id=\(id) error=\(error)")
                #endif
            }
        }
        #if DEBUG
        print("[WorkTaskTypeSync] fetched \(array.count) row(s), decoded \(records.count) for vineyard \(vineyardId.uuidString)")
        #endif
        return records
    }

    func upsertMany(_ items: [BackendWorkTaskTypeUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("work_task_types").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_work_task_type", params: SoftDeleteByIdRequest(id: id)).execute()
    }
}

// MARK: - Saved Inputs

final class SupabaseSavedInputSyncRepository: SavedInputSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendSavedInput] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("saved_inputs").select().eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await q.gte("updated_at", value: iso(since)).order("updated_at", ascending: true).execute().value
        }
        return try await q.order("updated_at", ascending: true).execute().value
    }

    func upsertMany(_ items: [BackendSavedInputUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("saved_inputs").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_saved_input", params: SoftDeleteByIdRequest(id: id)).execute()
    }
}

// MARK: - Equipment Items ("Other")

final class SupabaseEquipmentItemSyncRepository: EquipmentItemSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendEquipmentItem] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("equipment_items").select().eq("vineyard_id", value: vineyardId.uuidString)
        let data: Data
        if let since {
            data = try await q.gte("updated_at", value: iso(since)).order("updated_at", ascending: true).execute().data
        } else {
            data = try await q.order("updated_at", ascending: true).execute().data
        }
        let decoder = JSONDecoder()
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            #if DEBUG
            print("[EquipmentItemSync] fetch: unexpected payload shape, falling back to typed decode")
            #endif
            if let since {
                return try await q.gte("updated_at", value: iso(since)).order("updated_at", ascending: true).execute().value
            }
            return try await q.order("updated_at", ascending: true).execute().value
        }
        var records: [BackendEquipmentItem] = []
        records.reserveCapacity(array.count)
        for row in array {
            let id = (row["id"] as? String) ?? "<unknown-id>"
            do {
                let rowData = try JSONSerialization.data(withJSONObject: row)
                let record = try decoder.decode(BackendEquipmentItem.self, from: rowData)
                records.append(record)
            } catch {
                #if DEBUG
                print("[EquipmentItemSync] decode failed id=\(id) error=\(error)")
                #endif
            }
        }
        #if DEBUG
        print("[EquipmentItemSync] fetched \(array.count) row(s), decoded \(records.count) for vineyard \(vineyardId.uuidString)")
        #endif
        return records
    }

    func upsertMany(_ items: [BackendEquipmentItemUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("equipment_items").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_equipment_item", params: SoftDeleteByIdRequest(id: id)).execute()
    }
}
