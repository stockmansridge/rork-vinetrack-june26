import Foundation

protocol GrowthStageRecordSyncRepositoryProtocol: Sendable {
    func fetchGrowthStageRecords(vineyardId: UUID, since: Date?) async throws -> [BackendGrowthStageRecord]
    /// Positive, vineyard-scoped lookup by canonical pin ID, not by generated mirror record ID.
    func fetchActiveRecordsForPins(_ pinIds: Set<UUID>, vineyardId: UUID) async throws -> [BackendGrowthStageRecord]
    func upsertGrowthStageRecord(_ record: BackendGrowthStageRecordUpsert) async throws
    func upsertGrowthStageRecords(_ records: [BackendGrowthStageRecordUpsert]) async throws
    func updatePhotoPaths(recordId: UUID, vineyardId: UUID, photoPaths: [String]) async throws -> AttachmentReferenceConfirmation
    func softDeleteGrowthStageRecord(id: UUID) async throws
}


extension GrowthStageRecordSyncRepositoryProtocol {
    /// Existing test repositories keep their conformance. Production overrides this
    /// with pin-scoped pagination, so the normal 1,000-row API limit is irrelevant.
    func fetchActiveRecordsForPins(_ pinIds: Set<UUID>, vineyardId: UUID) async throws -> [BackendGrowthStageRecord] {
        guard !pinIds.isEmpty else { return [] }
        return try await fetchGrowthStageRecords(vineyardId: vineyardId, since: nil)
            .filter { $0.vineyardId == vineyardId && $0.deletedAt == nil
                && $0.pinId.map(pinIds.contains) == true }
    }
