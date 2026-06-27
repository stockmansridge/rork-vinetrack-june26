import Foundation
import Supabase

final class SupabaseAppNoticeRepository: AppNoticeRepositoryProtocol {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func fetchAllNotices() async throws -> [BackendAppNotice] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .from("app_notices")
            .select()
            .order("priority", ascending: false)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func fetchActiveNotices() async throws -> [BackendAppNotice] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let rows: [BackendAppNotice] = try await provider.client
            .from("app_notices")
            .select()
            .eq("is_active", value: true)
            .is("deleted_at", value: nil)
            .order("priority", ascending: false)
            .order("created_at", ascending: false)
            .execute()
            .value
        return rows.filter { $0.isCurrentlyVisible() }
    }

    func upsertNotice(_ notice: AppNoticeUpsert) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .from("app_notices")
            .upsert(notice, onConflict: "id")
            .execute()
    }

    func softDeleteNotice(id: UUID, updatedBy: UUID?) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .from("app_notices")
            .update(SoftDeletePayload(deletedAt: Date(), isActive: false, updatedBy: updatedBy, clientUpdatedAt: Date()))
            .eq("id", value: id.uuidString)
            .execute()
    }
}

nonisolated private struct SoftDeletePayload: Encodable, Sendable {
    let deletedAt: Date
    let isActive: Bool
    let updatedBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case deletedAt = "deleted_at"
        case isActive = "is_active"
        case updatedBy = "updated_by"
        case clientUpdatedAt = "client_updated_at"
    }
}
