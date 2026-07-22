import Foundation

protocol SprayRecordSyncRepositoryProtocol: Sendable {
    func fetchSprayRecords(vineyardId: UUID, since: Date?) async throws -> [BackendSprayRecord]
    func fetchAllSprayRecords(vineyardId: UUID) async throws -> [BackendSprayRecord]
    func upsertSprayRecord(_ record: BackendSprayRecordUpsert) async throws
    func upsertSprayRecords(_ records: [BackendSprayRecordUpsert]) async throws
    func softDeleteSprayRecord(id: UUID) async throws
}
