import Foundation
import Supabase

@MainActor
final class SprayCompletionRepository {
    func fetchRecord(id: UUID) async throws -> BackendSprayRecord {
        try await SupabaseClientProvider.shared.client.from("spray_records")
            .select().eq("id", value: id.uuidString).single().execute().value
    }

    func complete(id: UUID, allowUnlinked: Bool) async throws -> SprayCompletionResponse {
        try await SupabaseClientProvider.shared.client
            .rpc("complete_spray_record", params: SprayCompletionRequest(p_spray_record_id: id, p_allow_unlinked: allowUnlinked))
            .execute().value
    }
}
