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
