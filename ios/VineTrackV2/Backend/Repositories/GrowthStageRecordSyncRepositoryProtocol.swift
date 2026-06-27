import Foundation

protocol GrowthStageRecordSyncRepositoryProtocol: Sendable {
    func fetchGrowthStageRecords(vineyardId: UUID, since: Date?) async throws -> [BackendGrowthStageRecord]
    func upsertGrowthStageRecord(_ record: BackendGrowthStageRecordUpsert) async throws
    func upsertGrowthStageRecords(_ records: [BackendGrowthStageRecordUpsert]) async throws
    func softDeleteGrowthStageRecord(id: UUID) async throws
}
