import Foundation

protocol PinSyncRepositoryProtocol: Sendable {
    func fetchPins(vineyardId: UUID, since: Date?) async throws -> [BackendPin]
    func fetchAllPins(vineyardId: UUID) async throws -> [BackendPin]
    func upsertPin(_ pin: BackendPinUpsert) async throws
    func upsertPins(_ pins: [BackendPinUpsert]) async throws
    func softDeletePin(id: UUID) async throws
}
