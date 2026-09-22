import Foundation
import Supabase

/// Supabase read/write repositories for Work Task Material Costs (sql/247).
///
/// Follows the existing operations-sync repository shape exactly: PostgREST
/// upsert on `id`, soft-delete through a security-definer RPC, per-row
/// resilient decoding so one malformed row cannot break a vineyard's sync.
///
/// No System Admin check appears anywhere in this file. Access is the normal
/// vineyard/work-task RLS contract; the temporary System-Admin-only exposure
/// lives solely in `WorkTaskMaterialCostsAccess`.

private nonisolated struct MaterialSoftDeleteByIdRequest: Encodable, Sendable {
    let id: UUID
    enum CodingKeys: String, CodingKey { case id = "p_id" }
}

private func materialIso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

/// Decode a PostgREST array row-by-row, skipping (and in DEBUG reporting) rows
/// that fail, so a single bad row never fails the whole read.
private func decodeMaterialRows<T: Decodable>(_ data: Data, entity: String) -> [T] {
    let decoder = JSONDecoder()
    guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return (try? decoder.decode([T].self, from: data)) ?? []
    }
    var rows: [T] = []
    rows.reserveCapacity(array.count)
    for row in array {
        do {
            let rowData = try JSONSerialization.data(withJSONObject: row)
            rows.append(try decoder.decode(T.self, from: rowData))
        } catch {
            #if DEBUG
            let id = (row["id"] as? String) ?? "<unknown-id>"
            print("[\(entity)] decode failed id=\(id) error=\(error)")
            #endif
        }
    }
    return rows
}

// MARK: - Protocols

/// Global base catalogue — READ ONLY. There is deliberately no write method:
/// the catalogue is system owned and sql/247 refuses every client write.
protocol MaterialCatalogueRepositoryProtocol: Sendable {
    func fetchCatalogue() async throws -> [BackendMaterialCatalogueItem]
}

protocol VineyardMaterialSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendVineyardMaterial]
    func upsertMany(_ items: [BackendVineyardMaterialUpsert]) async throws
    func softDelete(id: UUID) async throws
}

protocol WorkTaskMaterialSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendWorkTaskMaterial]
    func fetch(workTaskId: UUID) async throws -> [BackendWorkTaskMaterial]
    func upsertMany(_ items: [BackendWorkTaskMaterialUpsert]) async throws
    func softDelete(id: UUID) async throws
}

// MARK: - Base catalogue

final class SupabaseMaterialCatalogueRepository: MaterialCatalogueRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetchCatalogue() async throws -> [BackendMaterialCatalogueItem] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let data = try await provider.client
            .from("material_catalogue")
            .select()
            .order("sort_order", ascending: true)
            .execute()
            .data
        return decodeMaterialRows(data, entity: "MaterialCatalogue")
    }
}

// MARK: - Vineyard materials

final class SupabaseVineyardMaterialSyncRepository: VineyardMaterialSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendVineyardMaterial] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("vineyard_materials").select()
            .eq("vineyard_id", value: vineyardId.uuidString)
        let data: Data
        if let since {
            data = try await q.gte("updated_at", value: materialIso(since))
                .order("updated_at", ascending: true).execute().data
        } else {
            data = try await q.order("updated_at", ascending: true).execute().data
        }
        return decodeMaterialRows(data, entity: "VineyardMaterialSync")
    }

    func upsertMany(_ items: [BackendVineyardMaterialUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("vineyard_materials").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .rpc("soft_delete_vineyard_material", params: MaterialSoftDeleteByIdRequest(id: id))
            .execute()
    }
}

// MARK: - Work Task materials

final class SupabaseWorkTaskMaterialSyncRepository: WorkTaskMaterialSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendWorkTaskMaterial] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("work_task_materials").select()
            .eq("vineyard_id", value: vineyardId.uuidString)
        let data: Data
        if let since {
            data = try await q.gte("updated_at", value: materialIso(since))
                .order("updated_at", ascending: true).execute().data
        } else {
            data = try await q.order("updated_at", ascending: true).execute().data
        }
        return decodeMaterialRows(data, entity: "WorkTaskMaterialSync")
    }

    /// One task's lines — backs "retrieve the materials of this Work Task"
    /// without pulling the whole vineyard slice.
    func fetch(workTaskId: UUID) async throws -> [BackendWorkTaskMaterial] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let data = try await provider.client.from("work_task_materials").select()
            .eq("work_task_id", value: workTaskId.uuidString)
            .is("deleted_at", value: nil)
            .order("created_at", ascending: true)
            .execute()
            .data
        return decodeMaterialRows(data, entity: "WorkTaskMaterialSync")
    }

    func upsertMany(_ items: [BackendWorkTaskMaterialUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("work_task_materials").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .rpc("soft_delete_work_task_material", params: MaterialSoftDeleteByIdRequest(id: id))
            .execute()
    }
}
