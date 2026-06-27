import Foundation

protocol AuditRepositoryProtocol: Sendable {
    func log(vineyardId: UUID?, action: String, entityType: String, entityId: UUID?, details: String?) async
}
