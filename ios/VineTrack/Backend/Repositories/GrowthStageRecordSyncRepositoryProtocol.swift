import Foundation

protocol GrowthStageRecordSyncRepositoryProtocol: Sendable {
    func fetchGrowthStageRecords(vineyardId: UUID, since: Date?) async throws -> [BackendGrowthStageRecord]
    func fetchActiveRecordsForPins(_ pinIds: Set<UUID>, vineyardId: UUID) async throws -> [BackendGrowthStageRecord]
    func upsertGrowthStageRecord(_ record: BackendGrowthStageRecordUpsert) async throws
    func upsertGrowthStageRecords(_ records: [BackendGrowthStageRecordUpsert]) async throws
    func updatePhotoPaths(recordId: UUID, vineyardId: UUID, photoPaths: [String]) async throws -> AttachmentReferenceConfirmation
    func softDeleteGrowthStageRecord(id: UUID) async throws
}

extension GrowthStageRecordSyncRepositoryProtocol {
    func fetchActiveRecordsForPins(_ pinIds: Set<UUID>, vineyardId: UUID) async throws -> [BackendGrowthStageRecord] {
        guard !pinIds.isEmpty else { return [] }
        return try await fetchGrowthStageRecords(vineyardId: vineyardId, since: nil)
            .filter { $0.vineyardId == vineyardId && $0.deletedAt == nil && $0.pinId.map(pinIds.contains) == true }
    }
}
