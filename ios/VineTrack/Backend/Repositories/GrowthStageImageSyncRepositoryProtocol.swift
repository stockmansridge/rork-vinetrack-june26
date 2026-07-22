import Foundation

protocol GrowthStageImageSyncRepositoryProtocol: Sendable {
    func fetch(vineyardId: UUID, since: Date?) async throws -> [BackendGrowthStageImage]
    func upsertMany(_ items: [BackendGrowthStageImageUpsert]) async throws
    func softDelete(id: UUID) async throws
}
