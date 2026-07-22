import Foundation

protocol ButtonConfigSyncRepositoryProtocol: Sendable {
    func fetchButtonConfigs(vineyardId: UUID) async throws -> [BackendButtonConfig]
    func upsertButtonConfig(_ config: BackendButtonConfigUpsert) async throws
    func upsertButtonConfigs(_ configs: [BackendButtonConfigUpsert]) async throws
}
