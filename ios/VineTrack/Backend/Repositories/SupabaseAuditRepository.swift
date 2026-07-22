import Foundation
import Supabase

final class SupabaseAuditRepository: AuditRepositoryProtocol {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func log(vineyardId: UUID?, action: String, entityType: String, entityId: UUID?, details: String?) async {
        guard provider.isConfigured else { return }
        do {
            try await provider.client
                .from("audit_events")
                .insert(AuditEventInsert(vineyardId: vineyardId, action: action, entityType: entityType, entityId: entityId, details: details))
                .execute()
        } catch {
            print("Audit event failed: \(error.localizedDescription)")
        }
    }
}

nonisolated private struct AuditEventInsert: Encodable, Sendable {
    let vineyardId: UUID?
    let action: String
    let entityType: String
    let entityId: UUID?
    let details: String?

    enum CodingKeys: String, CodingKey {
        case vineyardId = "vineyard_id"
        case action
        case entityType = "entity_type"
        case entityId = "entity_id"
        case details
    }
}
