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

// MARK: - Work Task Piece Rate Rows (sql/188)

final class SupabaseWorkTaskPieceRateRowSyncRepository: WorkTaskPieceRateRowSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendWorkTaskPieceRateRow] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("work_task_piece_rate_rows").select().eq("vineyard_id", value: vineyardId.uuidString)
        let data: Data
        if let since {
            data = try await q.gte("updated_at", value: opsIso(since)).order("updated_at", ascending: true).execute().data
        } else {
            data = try await q.order("updated_at", ascending: true).execute().data
        }
        // Per-row resilient decode — one malformed snapshot must never stop the
        // rest of a vineyard's piece-rate history from loading.
        let decoder = JSONDecoder()
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            if let since {
                return try await q.gte("updated_at", value: opsIso(since)).order("updated_at", ascending: true).execute().value
            }
            return try await q.order("updated_at", ascending: true).execute().value
        }
        var rows: [BackendWorkTaskPieceRateRow] = []
        rows.reserveCapacity(array.count)
        for row in array {
            let id = (row["id"] as? String) ?? "<unknown-id>"
            do {
                let rowData = try JSONSerialization.data(withJSONObject: row)
                rows.append(try decoder.decode(BackendWorkTaskPieceRateRow.self, from: rowData))
            } catch {
                #if DEBUG
                print("[WorkTaskPieceRateRowSync] decode failed id=\(id) error=\(error)")
                #endif
            }
        }
        return rows
    }

    func upsertMany(_ items: [BackendWorkTaskPieceRateRowUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("work_task_piece_rate_rows").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_work_task_piece_rate_row", params: OpsSoftDeleteByIdRequest(id: id)).execute()
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

// MARK: - Picking Records (Detailed picking log, sql/180)

final class SupabasePickingRecordSyncRepository: PickingRecordSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendPickingRecord] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("picking_records").select().eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await q.gte("updated_at", value: opsIso(since)).order("updated_at", ascending: true).execute().value
        }
        return try await q.order("updated_at", ascending: true).execute().value
    }

    func fetchFinancials(vineyardId: UUID) async throws -> [PickingFinancialRow] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .rpc("get_picking_record_financials", params: OpsVineyardIdRequest(vineyardId: vineyardId))
            .execute()
            .value
    }

    func upsertMany(_ items: [BackendPickingRecordUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !items.isEmpty else { return }
        try await provider.client.from("picking_records").upsert(items, onConflict: "id").execute()
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_picking_record", params: OpsSoftDeleteByIdRequest(id: id)).execute()
    }
}

nonisolated struct OpsVineyardIdRequest: Encodable, Sendable {
    let vineyardId: UUID
    nonisolated enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
    }
}

// MARK: - Bunch Count Trip sampling default (vineyards.yield_samples_per_hectare, sql/187)

/// Shared sample-density default for Bunch Count Trips. Members read; every
/// trip-capable role may write — a changed density becomes the default for
/// the NEXT trip on every device.
final class SupabaseYieldSamplingSettingsRepository: Sendable {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    private nonisolated struct Row: Decodable, Sendable {
        let samplesPerHectare: Int
        nonisolated enum CodingKeys: String, CodingKey {
            case samplesPerHectare = "samples_per_hectare"
        }
    }

    private nonisolated struct SetRequest: Encodable, Sendable {
        let vineyardId: UUID
        let samplesPerHectare: Int
        nonisolated enum CodingKeys: String, CodingKey {
            case vineyardId = "p_vineyard_id"
            case samplesPerHectare = "p_samples_per_hectare"
        }
    }

    func fetchDefault(vineyardId: UUID) async throws -> Int {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [Row] = try await provider.client
            .rpc("get_vineyard_yield_sampling_settings", params: OpsVineyardIdRequest(vineyardId: vineyardId))
            .execute()
            .value
        return rows.first?.samplesPerHectare ?? 20
    }

    @discardableResult
    func saveDefault(vineyardId: UUID, samplesPerHectare: Int) async throws -> Int {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [Row] = try await provider.client
            .rpc(
                "set_vineyard_yield_sampling_settings",
                params: SetRequest(vineyardId: vineyardId, samplesPerHectare: min(max(samplesPerHectare, 1), 100))
            )
            .execute()
            .value
        return rows.first?.samplesPerHectare ?? samplesPerHectare
    }
}

// MARK: - Pruning Yield Settings (per-block calculator configuration, sql/181)

final class SupabasePruningYieldSettingsSyncRepository: PruningYieldSettingsSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendPruningYieldSettings] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let q = provider.client.from("pruning_yield_settings").select().eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await q.gte("updated_at", value: opsIso(since)).order("updated_at", ascending: true).execute().value
        }
        return try await q.order("updated_at", ascending: true).execute().value
    }

    func upsertSettings(
        _ settings: PruningYieldSettings,
        createdBy: UUID?,
        clientUpdatedAt: Date
    ) async throws -> VersionedWriteOutcome<PruningYieldSettings> {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let payload = BackendPruningYieldSettings.upsert(
            from: settings,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
        do {
            // ONE saved configuration per block: conflict target is the
            // (vineyard_id, paddock_id) unique key, NOT the row id, so two devices
            // that minted different ids for the same block converge on one record.
            //
            // `.select()` asks for the representation back. It is NOT decoration: the response
            // body is the only place the new `server_revision` appears, and it is also how this
            // device learns which id the block converged on.
            let response = try await provider.client
                .from("pruning_yield_settings")
                .upsert(payload, onConflict: "vineyard_id,paddock_id")
                .select()
                .execute()
            return try VersionedWriteClassifier.classify(
                rowId: settings.id.uuidString,
                baseRevision: settings.serverRevision,
                status: response.status,
                body: String(data: response.data, encoding: .utf8)
            ) { text in
                guard let row = VersionedRepresentation.first(in: text) else { return nil }
                var applied = settings
                // Adopt the server's id: with a non-primary-key conflict target the surviving
                // row can legitimately be one another device minted.
                if let id = row.id { applied.id = id }
                applied.serverRevision = row.serverRevision
                return applied
            }
        } catch let error as VersionedWriteError {
            throw error
        } catch {
            // supabase-swift raises for a non-2xx, so a PT409 arrives here rather than as a
            // status. Routed through the SAME classifier as the raw-status path.
            if let outcome: VersionedWriteOutcome<PruningYieldSettings> = VersionedWriteClassifier.conflict(
                rowId: settings.id.uuidString,
                baseRevision: settings.serverRevision,
                from: error
            ) {
                return outcome
            }
            throw error
        }
    }

    func softDelete(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client.rpc("soft_delete_pruning_yield_settings", params: OpsSoftDeleteByIdRequest(id: id)).execute()
    }
}
