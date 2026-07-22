import Foundation
import Supabase

private nonisolated struct OpsSoftDeleteByIdRequest: Encodable, Sendable {
    let id: UUID
    enum CodingKeys: String, CodingKey { case id = "p_id" }
}

private func opsIso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

// MARK: - Work Tasks

final class SupabaseWorkTaskSyncRepository: WorkTaskSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendWorkTask] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("work_tasks").select().eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await q.gte("updated_at", value: opsIso(since)).order("updated_at", ascending: true).execute().value
        }
        return try await q.order("updated_at", ascending: true).execute().value
    }

    func upsertMany(_ items: [BackendWorkTaskUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("work_tasks").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_work_task", params: OpsSoftDeleteByIdRequest(id: id)).execute()
    }
}

// MARK: - Work Task Labour Lines

final class SupabaseWorkTaskLabourLineSyncRepository: WorkTaskLabourLineSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendWorkTaskLabourLine] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("work_task_labour_lines").select().eq("vineyard_id", value: vineyardId.uuidString)
        let data: Data
        if let since {
            data = try await q.gte("updated_at", value: opsIso(since)).order("updated_at", ascending: true).execute().data
        } else {
            data = try await q.order("updated_at", ascending: true).execute().data
        }
        // Per-row resilient decode — a single malformed row must not break
        // sync for the rest of the vineyard's labour lines.
        let decoder = JSONDecoder()
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            if let since {
                return try await q.gte("updated_at", value: opsIso(since)).order("updated_at", ascending: true).execute().value
            }
            return try await q.order("updated_at", ascending: true).execute().value
        }
        var rows: [BackendWorkTaskLabourLine] = []
        rows.reserveCapacity(array.count)
        for row in array {
            let id = (row["id"] as? String) ?? "<unknown-id>"
            do {
                let rowData = try JSONSerialization.data(withJSONObject: row)
                let decoded = try decoder.decode(BackendWorkTaskLabourLine.self, from: rowData)
                rows.append(decoded)
            } catch {
                #if DEBUG
                print("[WorkTaskLabourLineSync] decode failed id=\(id) error=\(error)")
                #endif
            }
        }
        #if DEBUG
        print("[WorkTaskLabourLineSync] fetched \(array.count) row(s), decoded \(rows.count) for vineyard \(vineyardId.uuidString)")
        #endif
        return rows
    }

    func upsertMany(_ items: [BackendWorkTaskLabourLineUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("work_task_labour_lines").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_work_task_labour_line", params: OpsSoftDeleteByIdRequest(id: id)).execute()
    }
}

// MARK: - Work Task Machine Lines

final class SupabaseWorkTaskMachineLineSyncRepository: WorkTaskMachineLineSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendWorkTaskMachineLine] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("work_task_machine_lines").select().eq("vineyard_id", value: vineyardId.uuidString)
        let data: Data
        if let since {
            data = try await q.gte("updated_at", value: opsIso(since)).order("updated_at", ascending: true).execute().data
        } else {
            data = try await q.order("updated_at", ascending: true).execute().data
        }
        // Per-row resilient decode — a single malformed row must not break
        // sync for the rest of the vineyard's machine lines.
        let decoder = JSONDecoder()
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            if let since {
                return try await q.gte("updated_at", value: opsIso(since)).order("updated_at", ascending: true).execute().value
            }
            return try await q.order("updated_at", ascending: true).execute().value
        }
        var rows: [BackendWorkTaskMachineLine] = []
        rows.reserveCapacity(array.count)
        for row in array {
            let id = (row["id"] as? String) ?? "<unknown-id>"
            do {
                let rowData = try JSONSerialization.data(withJSONObject: row)
                let decoded = try decoder.decode(BackendWorkTaskMachineLine.self, from: rowData)
                rows.append(decoded)
            } catch {
                #if DEBUG
                print("[WorkTaskMachineLineSync] decode failed id=\(id) error=\(error)")
                #endif
            }
        }
        #if DEBUG
        print("[WorkTaskMachineLineSync] fetched \(array.count) row(s), decoded \(rows.count) for vineyard \(vineyardId.uuidString)")
        #endif
        return rows
    }

    func upsertMany(_ items: [BackendWorkTaskMachineLineUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("work_task_machine_lines").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_work_task_machine_line", params: OpsSoftDeleteByIdRequest(id: id)).execute()
    }
}

// MARK: - Work Task Paddocks

final class SupabaseWorkTaskPaddockSyncRepository: WorkTaskPaddockSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendWorkTaskPaddock] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("work_task_paddocks").select().eq("vineyard_id", value: vineyardId.uuidString)
        let data: Data
        if let since {
            data = try await q.gte("updated_at", value: opsIso(since)).order("updated_at", ascending: true).execute().data
        } else {
            data = try await q.order("updated_at", ascending: true).execute().data
        }
        let decoder = JSONDecoder()
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            if let since {
                return try await q.gte("updated_at", value: opsIso(since)).order("updated_at", ascending: true).execute().value
            }
            return try await q.order("updated_at", ascending: true).execute().value
        }
        var rows: [BackendWorkTaskPaddock] = []
        rows.reserveCapacity(array.count)
        for row in array {
            let id = (row["id"] as? String) ?? "<unknown-id>"
            do {
                let rowData = try JSONSerialization.data(withJSONObject: row)
                let decoded = try decoder.decode(BackendWorkTaskPaddock.self, from: rowData)
                rows.append(decoded)
            } catch {
                #if DEBUG
                print("[WorkTaskPaddockSync] decode failed id=\(id) error=\(error)")
                #endif
            }
        }
        #if DEBUG
        print("[WorkTaskPaddockSync] fetched \(array.count) row(s), decoded \(rows.count) for vineyard \(vineyardId.uuidString)")
        #endif
        return rows
    }

    func upsertMany(_ items: [BackendWorkTaskPaddockUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("work_task_paddocks").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_work_task_paddock", params: OpsSoftDeleteByIdRequest(id: id)).execute()
    }
}

// MARK: - Maintenance Logs

final class SupabaseMaintenanceLogSyncRepository: MaintenanceLogSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendMaintenanceLog] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("maintenance_logs").select().eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await q.gte("updated_at", value: opsIso(since)).order("updated_at", ascending: true).execute().value
        }
        return try await q.order("updated_at", ascending: true).execute().value
    }

    func upsertMany(_ items: [BackendMaintenanceLogUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("maintenance_logs").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_maintenance_log", params: OpsSoftDeleteByIdRequest(id: id)).execute()
    }
}

// MARK: - Yield Estimation Sessions

final class SupabaseYieldEstimationSessionSyncRepository: YieldEstimationSessionSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendYieldEstimationSession] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("yield_estimation_sessions").select().eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await q.gte("updated_at", value: opsIso(since)).order("updated_at", ascending: true).execute().value
        }
        return try await q.order("updated_at", ascending: true).execute().value
    }

    func upsertMany(_ items: [BackendYieldEstimationSessionUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("yield_estimation_sessions").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_yield_estimation_session", params: OpsSoftDeleteByIdRequest(id: id)).execute()
    }
}

// MARK: - Damage Records

final class SupabaseDamageRecordSyncRepository: DamageRecordSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendDamageRecord] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("damage_records").select().eq("vineyard_id", value: vineyardId.uuidString)
        let data: Data
        if let since {
            data = try await q.gte("updated_at", value: opsIso(since)).order("updated_at", ascending: true).execute().data
        } else {
            data = try await q.order("updated_at", ascending: true).execute().data
        }
        // Per-row resilient decode: parse each row individually so a single bad
        // row (e.g. portal-created with an unexpected field shape) does not
        // hide the entire vineyard's damage records from iOS.
        let decoder = JSONDecoder()
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            #if DEBUG
            print("[DamageRecordSync] fetch: unexpected payload shape, falling back to typed decode")
            #endif
            if let since {
                return try await q.gte("updated_at", value: opsIso(since)).order("updated_at", ascending: true).execute().value
            }
            return try await q.order("updated_at", ascending: true).execute().value
        }
        var records: [BackendDamageRecord] = []
        records.reserveCapacity(array.count)
        for row in array {
            let id = (row["id"] as? String) ?? "<unknown-id>"
            do {
                let rowData = try JSONSerialization.data(withJSONObject: row)
                let record = try decoder.decode(BackendDamageRecord.self, from: rowData)
                records.append(record)
            } catch {
                #if DEBUG
                print("[DamageRecordSync] decode failed id=\(id) error=\(error)")
                #endif
            }
        }
        #if DEBUG
        print("[DamageRecordSync] fetched \(array.count) row(s), decoded \(records.count) for vineyard \(vineyardId.uuidString)")
        #endif
        return records
    }

    func upsertMany(_ items: [BackendDamageRecordUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("damage_records").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_damage_record", params: OpsSoftDeleteByIdRequest(id: id)).execute()
    }
}

// MARK: - Historical Yield Records

final class SupabaseHistoricalYieldRecordSyncRepository: HistoricalYieldRecordSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendHistoricalYieldRecord] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("historical_yield_records").select().eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await q.gte("updated_at", value: opsIso(since)).order("updated_at", ascending: true).execute().value
        }
        return try await q.order("updated_at", ascending: true).execute().value
    }

    func upsertMany(_ items: [BackendHistoricalYieldRecordUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("historical_yield_records").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_historical_yield_record", params: OpsSoftDeleteByIdRequest(id: id)).execute()
    }
}
