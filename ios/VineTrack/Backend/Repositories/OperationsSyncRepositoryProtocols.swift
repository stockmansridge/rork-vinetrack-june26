import Foundation

protocol WorkTaskSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendWorkTask]
    func upsertMany(_ items: [BackendWorkTaskUpsert]) async throws
    func softDelete(id: UUID) async throws
}

protocol WorkTaskLabourLineSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendWorkTaskLabourLine]
    func upsertMany(_ items: [BackendWorkTaskLabourLineUpsert]) async throws
    func softDelete(id: UUID) async throws
}

protocol WorkTaskMachineLineSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendWorkTaskMachineLine]
    func upsertMany(_ items: [BackendWorkTaskMachineLineUpsert]) async throws
    func softDelete(id: UUID) async throws
}

protocol WorkTaskPaddockSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendWorkTaskPaddock]
    func upsertMany(_ items: [BackendWorkTaskPaddockUpsert]) async throws
    func softDelete(id: UUID) async throws
}

/// Historical per-row vine-count snapshots behind piece-rate jobs (sql/188).
protocol WorkTaskPieceRateRowSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendWorkTaskPieceRateRow]
    func upsertMany(_ items: [BackendWorkTaskPieceRateRowUpsert]) async throws
    func softDelete(id: UUID) async throws
}

protocol MaintenanceLogSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendMaintenanceLog]
    func upsertMany(_ items: [BackendMaintenanceLogUpsert]) async throws
    func softDelete(id: UUID) async throws
}

protocol YieldEstimationSessionSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendYieldEstimationSession]
    func upsertMany(_ items: [BackendYieldEstimationSessionUpsert]) async throws
    func softDelete(id: UUID) async throws
}

protocol DamageRecordSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendDamageRecord]
    func upsertMany(_ items: [BackendDamageRecordUpsert]) async throws
    func softDelete(id: UUID) async throws
}

protocol HistoricalYieldRecordSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendHistoricalYieldRecord]
    func upsertMany(_ items: [BackendHistoricalYieldRecordUpsert]) async throws
    func softDelete(id: UUID) async throws
}

protocol PickingRecordSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendPickingRecord]
    /// Owner/manager-only commercial projection (sql/187). Raises for lower
    /// roles — callers swallow the failure and keep masked NULLs.
    func fetchFinancials(vineyardId: UUID) async throws -> [PickingFinancialRow]
    func upsertMany(_ items: [BackendPickingRecordUpsert]) async throws
    func softDelete(id: UUID) async throws
}

protocol PruningYieldSettingsSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendPruningYieldSettings]
    /// Upserts ONE block's calculator configuration under the sql/198 revision contract.
    ///
    /// One request per block, deliberately: a multi-row upsert is a single transaction, so one
    /// REVISION_CONFLICT would abort every other block's write in the batch.
    ///
    /// Returns ``VersionedWriteOutcome/applied(_:)`` carrying the authoritative row (with its
    /// NEW `server_revision`, and the id the block converged on), or
    /// ``VersionedWriteOutcome/conflict(rowId:baseRevision:serverRevision:)``. A conflict is
    /// NEVER thrown — a thrown conflict is retried forever with the same stale `base_revision`.
    func upsertSettings(
        _ settings: PruningYieldSettings,
        createdBy: UUID?,
        clientUpdatedAt: Date
    ) async throws -> VersionedWriteOutcome<PruningYieldSettings>
    func softDelete(id: UUID) async throws
}
